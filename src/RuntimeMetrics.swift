// ============================================================
// 运行时指标层：内存里这个模型「这一趟」跑了多久、喂进去多快、吐出来多快
// ============================================================
//
// 三条来源，按可靠性排序：
//   ① Prometheus `/metrics`（llama.cpp / vLLM / SGLang / TGI 都有）—— 累计计数器，
//      平均值 = 总数 ÷ 累计秒数，最准；
//   ② 引擎自己的日志（Splash / Strata 这类把每轮 tok/s 打出来的）——
//      按「本次加载」的起始标记切分，只统计这一趟；
//   ③ 都拿不到就只显示进程运行时间，并在界面写明「未配置指标来源」，不编数字。
//
// 关于 prefill：Splash 的日志只给 input / cached / TTFT，平均 prefill 速度按
//   (input − cached − deduplicated) ÷ TTFT 算；命中前缀缓存的请求不参与平均
//   （那部分根本没重新算，算进去会把速度吹上天）。

import Cocoa

// ============================================================
// MARK: - 进程启动时间（运行时间 = now − 启动时间）
// ============================================================

func processStartDate(_ pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
    guard r > 0 else { return nil }
    let sec = TimeInterval(info.pbi_start_tvsec)
    let usec = TimeInterval(info.pbi_start_tvusec) / 1_000_000
    guard sec > 0 else { return nil }
    return Date(timeIntervalSince1970: sec + usec)
}

func prettyUptime(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s) 秒" }
    let m = s / 60, h = m / 60, d = h / 24
    if d > 0 { return "\(d) 天 \(h % 24) 小时" }
    if h > 0 { return "\(h) 小时 \(m % 60) 分" }
    return "\(m) 分 \(s % 60) 秒"
}

// ============================================================
// MARK: - 指标模型
// ============================================================

struct RuntimeMetric {
    var uptime: TimeInterval? = nil
    var prefillTokS: Double? = nil
    var decodeTokS: Double? = nil
    var requests: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var ttftAvgS: Double? = nil
    var source: String = ""
    var note: String = ""
    var lastRequestAt: Date? = nil
    /// 生图 / 视频专用：轮次 / 每轮耗时 / 当前这轮已用时间。
    /// 有它就**不再显示** prefill / decode —— 媒体模型没有这两个阶段。
    var media: MediaMetric? = nil
    var hasThroughput: Bool { prefillTokS != nil || decodeTokS != nil }
}

// ============================================================
// MARK: - 日志会话解析（按「本次加载」切分）
// ============================================================

struct LogTotals {
    var requests = 0
    var tokensIn = 0
    var tokensOut = 0
    var prefillTokens = 0
    var prefillSeconds = 0.0
    var decodeSeconds = 0.0
    var ttftSum = 0.0
    var ttftCount = 0
    var lastRequestAt: Date? = nil

    mutating func reset() { self = LogTotals() }

    var prefillTokS: Double? { prefillSeconds > 0.05 && prefillTokens > 0 ? Double(prefillTokens) / prefillSeconds : nil }
    var decodeTokS: Double? { decodeSeconds > 0.05 && tokensOut > 0 ? Double(tokensOut) / decodeSeconds : nil }
    var ttftAvg: Double? { ttftCount > 0 ? ttftSum / Double(ttftCount) : nil }
}

protocol LogSessionProfile: AnyObject {
    var displayName: String { get }
    func isSessionStart(_ line: String) -> Bool
    func consume(_ line: String)
    var totals: LogTotals { get }
    func reset()
}

// ---- Splash：`Done · input 4,184 · cached 0 · deduplicated 96 · output 900 · TTFT 3.5s · 74.0 tok/s · 2.1 tok/cycle`
final class SplashLogProfile: LogSessionProfile {
    let displayName = "Splash 日志"
    private(set) var totals = LogTotals()
    private let re = try! NSRegularExpression(
        pattern: #"Done · input ([\d,]+) · cached ([\d,]+)(?: · deduplicated ([\d,]+))? · output ([\d,]+) · TTFT ([\d.]+)s · ([\d.]+) tok/s"#)

    func isSessionStart(_ line: String) -> Bool {
        line.contains("Loading ·") || line.contains("Ready ·")
    }

    func reset() { totals = LogTotals() }

    func consume(_ line: String) {
        guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return }
        func g(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: line) else { return nil }
            return String(line[r])
        }
        guard let inputS = g(1), let cachedS = g(2), let outputS = g(4),
              let ttftS = g(5), let rateS = g(6),
              let input = Int(inputS.replacingOccurrences(of: ",", with: "")),
              let cached = Int(cachedS.replacingOccurrences(of: ",", with: "")),
              let output = Int(outputS.replacingOccurrences(of: ",", with: "")),
              let ttft = Double(ttftS), let rate = Double(rateS), rate > 0.5 else { return }
        let dedup = g(3).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } ?? 0
        totals.requests += 1
        totals.tokensIn += input
        totals.tokensOut += output
        totals.ttftSum += ttft
        totals.ttftCount += 1
        totals.decodeSeconds += Double(output) / rate
        let fresh = max(0, input - cached - dedup)
        if fresh > 0, ttft > 0.02 {
            totals.prefillTokens += fresh
            totals.prefillSeconds += ttft
        }
        totals.lastRequestAt = Date()
    }
}

// ---- Strata：`[strata] reading the prompt: 167,223 of 168,953 tokens, 82 s so far`
//              `[strata] done: 223 tokens in 85 s (114.9 tok/s) (stop, cancel=False)`
final class StrataLogProfile: LogSessionProfile {
    let displayName = "Strata 日志"
    private(set) var totals = LogTotals()
    private var pendingPrefillTokens = 0
    private var pendingPrefillSeconds = 0.0
    private var pendingInput = 0
    private let reRead = try! NSRegularExpression(pattern: #"reading the prompt: ([\d,]+) of ([\d,]+) tokens, (\d+) s"#)
    private let reDone = try! NSRegularExpression(pattern: #"done: ([\d,]+) tokens in (\d+) s \(([\d.]+) tok/s\)"#)

    func isSessionStart(_ line: String) -> Bool {
        line.contains("starting the engine: reading the model") || line.contains("loading the model (")
    }

    func reset() {
        totals = LogTotals()
        pendingPrefillTokens = 0
        pendingPrefillSeconds = 0
        pendingInput = 0
    }

    func consume(_ line: String) {
        if let m = reRead.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            func g(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: line) else { return nil }
                return String(line[r])
            }
            if let n = g(1).flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }),
               let t = g(3).flatMap({ Double($0) }) {
                pendingPrefillTokens = n
                pendingPrefillSeconds = t
            }
            if let all = g(2).flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }) {
                pendingInput = all
            }
            return
        }
        if let m = reDone.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            func g(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: line) else { return nil }
                return String(line[r])
            }
            guard let n = g(1).flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }),
                  let rate = g(3).flatMap({ Double($0) }), rate > 0.5 else { return }
            totals.requests += 1
            totals.tokensOut += n
            totals.decodeSeconds += Double(n) / rate
            totals.tokensIn += pendingInput
            // 注意：Strata 的 `reading the prompt` 把**前缀缓存命中**也算进秒数，
            // 拿它算 prefill 会得到 1 万 tok/s 这种假数。prefill 只从 /metrics 的
            // prompt_read / prompt_ms 取（那是真读进上下文的 token）。日志兜底只给 decode。
            _ = pendingPrefillTokens
            _ = pendingPrefillSeconds
            totals.lastRequestAt = Date()
            pendingPrefillTokens = 0
            pendingPrefillSeconds = 0
            pendingInput = 0
        }
    }
}

// ============================================================
// MARK: - 日志增量读取器
// ============================================================

final class LogAggregator {
    let path: String
    private let profile: LogSessionProfile
    private var offset: UInt64 = 0
    private var initialized = false
    private var carry = Data()
    private var lastError: String?

    init(path: String, profile: LogSessionProfile) {
        self.path = path
        self.profile = profile
    }

    var errorText: String? { lastError }

    /// 从上次位置读到文件尾，只解析新增的行。返回 null 表示文件不可读。
    func refresh() -> LogTotals? {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            lastError = "日志不可读"
            return nil
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        lastError = nil

        if !initialized || size < offset {
            // 首次 / 文件被截断（轮转）：从最后一个「会话开始」标记之后开始读
            profile.reset()
            offset = findSessionStart(file: fh, size: size)
            carry = Data()
            initialized = true
        }
        guard size > offset else { return profile.totals }

        // 单次最多读 8 MB：一趟会话写不了这么多标记行，读不完的部分下一轮继续
        let want = Int(min(UInt64(8 << 20), size - offset))
        try? fh.seek(toOffset: offset)
        guard let chunk = try? fh.read(upToCount: want), !chunk.isEmpty else { return profile.totals }
        offset += UInt64(chunk.count)

        var data = carry
        data.append(chunk)
        carry = Data()
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<nl]
            data = data[(nl + 1)...]
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if profile.isSessionStart(line) { profile.reset(); continue }
            profile.consume(line)
        }
        // 末尾没换行的半行留到下一轮（日志写入可能正卡在中间）
        if data.count > 0 { carry = Data(data) }
        return profile.totals
    }

    /// 往回找最后一个会话开始标记所在行的**下一个字节位置**
    private func findSessionStart(file: FileHandle, size: UInt64) -> UInt64 {
        let chunkSize: UInt64 = 1 << 20
        let maxScan: UInt64 = 24 << 20
        var hi = size
        var scanned: UInt64 = 0
        while hi > 0 && scanned < maxScan {
            let lo = hi > chunkSize ? hi - chunkSize : 0
            try? file.seek(toOffset: lo)
            guard let data = try? file.read(upToCount: Int(hi - lo)), !data.isEmpty else { break }
            var searchEnd = data.endIndex
            // 最后一块的末尾可能是不完整行，但标记判断不受影响：按行切开逐条找
            while searchEnd > data.startIndex {
                let slice = data[data.startIndex..<searchEnd]
                guard let nl = slice.lastIndex(of: 0x0A) else { break }
                let lineData = data[(nl + 1)..<searchEnd]
                if let line = String(data: lineData, encoding: .utf8), profile.isSessionStart(line) {
                    // 行首 = 换行之后那个字节（绝对偏移）
                    let lineStart = data.distance(from: data.startIndex, to: nl) + 1
                    return lo + UInt64(lineStart)
                }
                searchEnd = nl
            }
            scanned += (hi - lo)
            hi = lo
        }
        // 没找到标记：只回看最后 1 MB（老日志里没有本次会话，平均会被历史拉偏）
        return size > (1 << 20) ? size - (1 << 20) : 0
    }
}

// ============================================================
// MARK: - Prometheus /metrics
// ============================================================

enum Prometheus {
    /// 解析 `name{labels} value` 行，返回 name → value（同名多行求和）
    static func parse(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let v = Double(parts[1]) else { continue }
            var name = String(parts[0])
            if let brace = name.firstIndex(of: "{") { name = String(name[..<brace]) }
            out[name, default: 0] += v
        }
        return out
    }

    /// 从一堆计数器里认出「预填充 / 解码」的累计 token 与秒数（llama.cpp 与 vLLM 命名不同）
    static func throughput(_ m: [String: Double]) -> (prefill: Double?, decode: Double?, requests: Int,
                                                      tokensIn: Int, tokensOut: Int, ttft: Double?) {
        func pick(_ names: [String]) -> Double? {
            for n in names where (m[n] ?? 0) > 0 { return m[n] }
            return nil
        }
        let promptTokens = pick(["llamacpp:prompt_tokens_total", "vllm:prompt_tokens_total",
                                 "tgi:prompt_tokens_total", "sglang:prompt_tokens_total"])
        let promptSeconds = pick(["llamacpp:prompt_seconds_total", "vllm:request_prefill_time_seconds_sum",
                                  "tgi:prefill_time_seconds_sum", "sglang:prompt_time_seconds_sum"])
        let genTokens = pick(["llamacpp:tokens_predicted_total", "vllm:generation_tokens_total",
                              "tgi:generated_tokens_total", "sglang:generation_tokens_total"])
        let genSeconds = pick(["llamacpp:tokens_predicted_seconds_total", "vllm:request_decode_time_seconds_sum",
                               "tgi:generation_time_seconds_sum", "sglang:decode_time_seconds_sum"])
        let requests = Int(pick(["llamacpp:requests_total", "vllm:num_requests_success_total",
                                 "tgi:requests_total", "sglang:num_requests_total"]) ?? 0)
        let ttftSum = pick(["vllm:time_to_first_token_seconds_sum", "tgi:time_to_first_token_seconds_sum"])
        let ttftCount = pick(["vllm:time_to_first_token_seconds_count", "tgi:time_to_first_token_seconds_count"])
        let prefill = (promptTokens != nil && (promptSeconds ?? 0) > 0.05)
            ? promptTokens! / promptSeconds! : nil
        let decode = (genTokens != nil && (genSeconds ?? 0) > 0.05) ? genTokens! / genSeconds! : nil
        let ttft = (ttftSum != nil && (ttftCount ?? 0) > 0) ? ttftSum! / ttftCount! : nil
        return (prefill, decode, requests, Int(promptTokens ?? 0), Int(genTokens ?? 0), ttft)
    }
}

// ============================================================
// MARK: - JSON 指标（Strata 的 /metrics）
// ============================================================
//
// Strata 的 /metrics 不是 Prometheus 文本，而是一份 JSON：
//   totals:   { requests, prompt_tokens, reused, output_tokens, prompt_ms, decode_ms }
//   requests: [ { prompt_tokens, reused, prompt_read, prompt_ms, decode_ms, decode_tok_s,
//                 output_tokens, duration_s, finish } ]
//   since:    这次加载开始的 epoch 秒
//
// 其中 prompt_read 是**真正读进上下文的** token（不含前缀缓存），
// 所以 prefill = Σprompt_read ÷ Σprompt_ms —— 这才是「refill 速度」的真值；
// 引擎日志里的 `reading the prompt: 47,721 of 47,726 tokens, 1 s` 是缓存命中，不能拿来平均。

enum JSONMetrics {
    static func fetch(port: Int) -> RuntimeMetric? {
        guard let body = LocalHTTP.body(port: port, path: "/metrics", timeoutMs: 800,
                                        maxBytes: 1024 * 1024),
              let data = body.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(obj)
    }

    /// 纯函数：给一份 /metrics 的 JSON，算出平均 prefill / decode / 请求与 token 量。
    /// （自检直接喂合成数据，不依赖真的引擎在跑。）
    static func parse(_ obj: [String: Any]) -> RuntimeMetric? {
        guard let totals = obj["totals"] as? [String: Any] else { return nil }

        var out = RuntimeMetric()
        out.requests = (totals["requests"] as? NSNumber)?.intValue ?? 0
        out.tokensIn = (totals["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        out.tokensOut = (totals["output_tokens"] as? NSNumber)?.intValue ?? 0
        if let since = (obj["since"] as? NSNumber)?.doubleValue ?? (totals["since"] as? NSNumber)?.doubleValue,
           since > 1_000_000 {
            out.uptime = Date().timeIntervalSince1970 - since
        }

        if let reqs = obj["requests"] as? [[String: Any]], !reqs.isEmpty {
            var readTokens = 0.0, promptMs = 0.0, outTokens = 0.0, decodeMs = 0.0
            var counted = 0
            for r in reqs {
                let read = (r["prompt_read"] as? NSNumber)?.doubleValue
                    ?? (r["prompt_tokens"] as? NSNumber)?.doubleValue ?? 0
                let pm = (r["prompt_ms"] as? NSNumber)?.doubleValue ?? 0
                let ot = (r["output_tokens"] as? NSNumber)?.doubleValue ?? 0
                let dm = (r["decode_ms"] as? NSNumber)?.doubleValue ?? 0
                if read > 0, pm > 0 { readTokens += read; promptMs += pm }
                if ot > 0, dm > 0 { outTokens += ot; decodeMs += dm; counted += 1 }
            }
            if promptMs > 50 { out.prefillTokS = readTokens / (promptMs / 1000) }
            if decodeMs > 50 { out.decodeTokS = outTokens / (decodeMs / 1000) }
            if counted > 0 {
                out.ttftAvgS = (promptMs / 1000) / Double(counted)
            }
        }
        if let live = obj["live"] as? [String: Any],
           let mean = (live["prefill_tok_s_mean"] as? NSNumber)?.doubleValue, mean > 0,
           out.prefillTokS == nil {
            out.prefillTokS = mean
        }
        out.source = "引擎 /metrics（JSON 累计 · prefill 用 prompt_read）"
        return out
    }
}

// ============================================================
// MARK: - 指标仓库（按端口/日志缓存，别每帧重读）
// ============================================================

final class MetricsStore {
    private var aggregators: [String: LogAggregator] = [:]
    private var promCache: [Int: (at: Date, values: [String: Double])] = [:]
    private let media = MediaMetricsStore()

    static func profile(named name: String) -> LogSessionProfile? {
        switch name.lowercased() {
        case "splash": return SplashLogProfile()
        case "strata", "flash-next", "flashnext": return StrataLogProfile()
        default: return nil
        }
    }

    private func aggregator(path: String, profile: String) -> LogAggregator? {
        let key = path + "|" + profile
        if let a = aggregators[key] { return a }
        guard let p = MetricsStore.profile(named: profile) else { return nil }
        let a = LogAggregator(path: path, profile: p)
        aggregators[key] = a
        return a
    }

    private func prometheus(port: Int) -> [String: Double]? {
        if let c = promCache[port], Date().timeIntervalSince(c.at) < 3 {
            return c.values.isEmpty ? nil : c.values
        }
        guard let body = LocalHTTP.body(port: port, path: "/metrics", timeoutMs: 500, maxBytes: 256 * 1024) else {
            promCache[port] = (Date(), [:])
            return nil
        }
        let vals = Prometheus.parse(body)
        promCache[port] = (Date(), vals)
        return vals.isEmpty ? nil : vals
    }

    /// 组装一个模型的运行时指标。
    /// - recipe：启动配方（里面有 log / metrics 声明）
    /// - port：服务端口（Prometheus 用）
    /// - pid：持有进程（运行时间用）
    func metric(for row: ModelRow, recipe: LaunchRecipe?) -> RuntimeMetric? {
        var out = RuntimeMetric()

        if let pid = row.pid, let start = processStartDate(pid) {
            out.uptime = Date().timeIntervalSince(start)
        }

        // ⓪ 生图 / 视频：一轮一张图、一段片子，没有 prefill / decode 这回事。
        //    配方声明了 media 就走媒体探针，并且**直接返回** —— 免得 mlx-serve 的
        //    Prometheus /metrics 把 LLM 计数器（prompt_tokens 之类）混进来当「解码速度」。
        if let recipe = recipe, let kind = recipe.mediaKind {
            if let probe = media.probe(for: recipe, port: row.port),
               var m = probe.refresh(now: Date()) {
                m.kind = kind
                out.media = m
                out.source = m.source
                out.note = m.note
                return out
            }
            // 引擎没在跑 / 日志读不到：只留运行时间，并把原因写清楚（不编轮次）
            let src = (recipe.media ?? "").lowercased()
            out.note = "媒体指标未取到（\(src) 探针不可用：引擎未运行或日志不可读）"
            if out.uptime == nil { return nil }
            return out
        }

        // ① JSON /metrics（Strata）
        if let port = row.port, let j = JSONMetrics.fetch(port: port) {
            out.prefillTokS = j.prefillTokS
            out.decodeTokS = j.decodeTokS
            out.requests = j.requests
            out.tokensIn = j.tokensIn
            out.tokensOut = j.tokensOut
            out.ttftAvgS = j.ttftAvgS
            if out.uptime == nil { out.uptime = j.uptime }
            out.source = j.source
            return out
        }

        // ② Prometheus
        let wantsProm = (recipe?.metrics?.lowercased() == "prometheus")
            || ["llama.cpp", "vLLM", "SGLang", "TGI"].contains(where: { row.engine.localizedCaseInsensitiveContains($0) })
        if wantsProm, let port = row.port, let vals = prometheus(port: port) {
            let t = Prometheus.throughput(vals)
            out.prefillTokS = t.prefill
            out.decodeTokS = t.decode
            out.requests = t.requests
            out.tokensIn = t.tokensIn
            out.tokensOut = t.tokensOut
            out.ttftAvgS = t.ttft
            out.source = "引擎 /metrics（累计计数器）"
        }

        // ③ 日志
        if !out.hasThroughput,
           let recipe = recipe,
           let profileName = recipe.metrics,
           let logPath = recipe.log?.expandingTildePath,
           let agg = aggregator(path: logPath, profile: profileName),
           let totals = agg.refresh() {
            if let p = totals.prefillTokS { out.prefillTokS = p }
            if let d = totals.decodeTokS { out.decodeTokS = d }
            out.requests = totals.requests
            out.tokensIn = totals.tokensIn
            out.tokensOut = totals.tokensOut
            out.ttftAvgS = totals.ttftAvg
            out.lastRequestAt = totals.lastRequestAt
            out.source = "\((MetricsStore.profile(named: profileName)?.displayName) ?? "日志") · 自本次加载起"
        } else if !out.hasThroughput, let recipe = recipe, let logPath = recipe.log {
            out.note = "日志解析不可用（\(logPath)）"
        }

        if out.uptime == nil && !out.hasThroughput && out.source.isEmpty { return nil }
        return out
    }
}
