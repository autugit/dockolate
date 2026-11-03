// ============================================================
// 媒体运行时指标：生图 / 视频没有「预填充 / 解码」这回事
// ============================================================
//
// 一轮 = 一张图 或 一段片子。要回答的只有三件事：
//   ① 这一趟出了多少轮（几张 / 几段）
//   ② 每轮多久（平均 / 最近 / 最快最慢）
//   ③ **当前**这一轮已经跑了多久（视频再带 步 12/20）
//
// 「一次请求 = 一张图」这个前提是错的：ComfyUI 一个 prompt 可能出多张（batch），
// H3 的 chain_windows 一个请求会串好几窗 —— 所以轮次一律按**产物边界**数，
// 不按 HTTP 请求数。
//
// 两条来源，都是引擎自己记的账：
//   · ComfyUI：`/queue`（正在跑的是哪个 prompt）+ `/history`（每条 prompt 的
//     execution_start / execution_success 时间戳）—— 轮次与每轮耗时是引擎真值。
//     正在跑的那轮没有时间戳可用，只能按「第一次在 /queue 里看见它的时刻」起算，
//     误差不超过轮询间隔。
//   · mlx-serve（H3 视频）：引擎日志 ——
//       `[minimax-h3] 576x384 124 frames (37 latent, 207 audio), 20 steps`  一轮开始
//       `[minimax-h3] step 12/20 sigma … (2781 ms)`                          进度
//       `[video] -> 124f 384x576 (82280448 rgb bytes)`                       出片
//     日志行没有时间戳，耗时同样按「观测到这两行」的钟差算（轮询粒度）。
//
// 观测口径写进 source / note：界面照实说明「自本次启动」「误差一个轮询周期」，
// 拿不到就返回 nil —— 不编数字。

import Foundation

enum MediaKind: String {
    case image, video

    /// 计数单位：张 = 图，段 = 片子
    var unit: String { self == .image ? "张" : "段" }
    /// 还没产出任何东西时的说法
    var idleVerb: String { self == .image ? "还没出过图" : "还没出过片" }
}

struct MediaMetric {
    var kind: MediaKind = .image
    /// 本次会话已完成的轮次（一次执行 = 一轮）
    var rounds = 0
    /// 实际产出的件数（ComfyUI 一轮可能出多张图；拿不到就 nil，按 1:1 显示）
    var products: Int? = nil
    /// 每次产物的耗时（秒，升序不重要，按发生顺序）
    var durations: [Double] = []
    /// 当前这轮已用秒数；nil = 当前没有任务
    var currentElapsedS: Double? = nil
    /// 当前是第几轮（= rounds + 1）
    var currentIndex: Int? = nil
    var currentStep: Int? = nil
    var currentStepTotal: Int? = nil
    /// 排在后面等着的任务数（ComfyUI 有队列；mlx-serve 是串行 HTTP，恒为 0）
    var queued = 0
    /// 最近一次产物的规格（视频：帧数 / 分辨率）
    var lastFrames: Int? = nil
    var lastSize: String? = nil
    /// 最近一次出产的时刻
    var lastAt: Date? = nil
    var source = ""
    var note = ""

    var isBusy: Bool { currentElapsedS != nil }
    var avgS: Double? {
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }
    var lastS: Double? { durations.last }
    var minS: Double? { durations.min() }
    var maxS: Double? { durations.max() }
}

// ============================================================
// MARK: - 探针协议
// ============================================================

protocol MediaProbe: AnyObject {
    var kind: MediaKind { get }
    /// 读一次引擎状态；引擎不在 / 读不到就返回 nil（界面写「未取到」，不编）。
    func refresh(now: Date) -> MediaMetric?
}

// ============================================================
// MARK: - ComfyUI：/queue + /history
// ============================================================

final class ComfyMediaProbe: MediaProbe {
    let kind: MediaKind = .image
    private let port: Int
    /// prompt_id → 第一次在 /queue 里看见它的时刻（正在跑那轮的起算点）
    private var seenRunning: [String: Date] = [:]
    /// 上一轮读到的 history 条数：变小 ⇒ 服务重启过（history 在内存里），本地记账跟着重置
    private var lastHistoryCount = -1

    init(port: Int) { self.port = port }

    static func json(_ text: String) -> Any? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    func refresh(now: Date) -> MediaMetric? {
        guard let qBody = LocalHTTP.body(port: port, path: "/queue", timeoutMs: 700, maxBytes: 4 << 20),
              let qObj = ComfyMediaProbe.json(qBody) as? [String: Any] else { return nil }

        var out = MediaMetric(kind: .image)
        let running = (qObj["queue_running"] as? [[Any]]) ?? []
        let pending = (qObj["queue_pending"] as? [[Any]]) ?? []
        out.queued = pending.count
        var runningID: String? = nil
        if let first = running.first, first.count > 1, let id = first[1] as? String { runningID = id }

        // ---- 历史：引擎自己打的开始 / 结束时间戳
        let hist = ComfyMediaProbe.parseHistory(
            (LocalHTTP.body(port: port, path: "/history?max_items=200",
                            timeoutMs: 900, maxBytes: 8 << 20).flatMap { ComfyMediaProbe.json($0) } as? [String: Any]) ?? [:])
        // history 条数变少 ⇒ 服务重启过：正在跑的记账不能跨重启复用
        if hist.total < lastHistoryCount { seenRunning.removeAll() }
        lastHistoryCount = hist.total

        out.rounds = hist.rounds
        out.products = hist.images
        out.durations = hist.durations
        if let end = hist.lastEnd { out.lastAt = Date(timeIntervalSince1970: end / 1000) }

        // ---- 正在跑的那轮
        if let id = runningID {
            if seenRunning[id] == nil { seenRunning[id] = now }
            out.currentElapsedS = now.timeIntervalSince(seenRunning[id] ?? now)
            out.currentIndex = out.rounds + 1
        }
        // 只保留还在跑的、以及最近 10 分钟内的记账（history 会自己清理，本地也清）
        seenRunning = seenRunning.filter { k, v in k == runningID || now.timeIntervalSince(v) < 600 }

        out.source = "ComfyUI /queue + /history（自本次启动）"
        var notes: [String] = []
        if hist.failed > 0 { notes.append("另有 \(hist.failed) 轮失败 / 中断（未计入轮次）") }
        if out.currentElapsedS != nil { notes.append("当前这轮按「首次在队列里看到它」起算，误差 ≤ 一个轮询周期") }
        out.note = notes.joined(separator: "；")
        return out
    }

    /// 纯函数：把一份 `/history` 的 JSON 折成轮次与耗时（自检直接喂合成数据）。
    /// 只认有 execution_start + execution_success 两个时间戳的条目；失败 / 中断单独计数。
    static func parseHistory(_ hist: [String: Any])
        -> (total: Int, rounds: Int, failed: Int, durations: [Double], lastEnd: Double?, images: Int) {
        var done: [(start: Double, end: Double, ok: Bool, images: Int)] = []
        var failed = 0
        for (_, raw) in hist {
            guard let item = raw as? [String: Any],
                  let st = item["status"] as? [String: Any] else { continue }
            var start: Double? = nil
            var end: Double? = nil
            var broken = false
            for msg in (st["messages"] as? [[Any]]) ?? [] {
                guard msg.count >= 2, let event = msg[0] as? String else { continue }
                let data = msg[1] as? [String: Any]
                let ts = (data?["timestamp"] as? NSNumber)?.doubleValue
                switch event {
                case "execution_start":   start = ts
                case "execution_success": end = ts
                case "execution_error", "execution_interrupted": broken = true
                default: break
                }
            }
            guard let s = start, let e = end, e >= s else {
                if broken { failed += 1 }
                continue
            }
            // 一执行出几件：数 outputs[*].images（排除 type=temp 的预览图）；
            // 完全没有图像输出（纯文本节点图）时按 1 件算，避免"轮次 3 / 产物 0"的自相矛盾。
            var imgs = 0
            if let outputs = item["outputs"] as? [String: Any] {
                for (_, nodeRaw) in outputs {
                    guard let node = nodeRaw as? [String: Any],
                          let list = node["images"] as? [[String: Any]] else { continue }
                    imgs += list.filter { (($0["type"] as? String) ?? "output") != "temp" }.count
                }
            }
            done.append((s, e, !broken, max(1, imgs)))
        }
        done.sort { $0.start < $1.start }
        let ok = done.filter { $0.ok }
        return (done.count,
                ok.count,
                failed + done.filter { !$0.ok }.count,
                ok.map { ($0.end - $0.start) / 1000 },
                done.last?.end,
                ok.reduce(0) { $0 + $1.images })
    }
}

// ============================================================
// MARK: - mlx-serve（H3 视频）：引擎日志
// ============================================================

final class MlxServeMediaProbe: MediaProbe {
    let kind: MediaKind
    private let path: String
    /// 首选的引擎日志（`~/.mlx-serve/logs/mlx-serve-<port>.log`），不存在时用调用方给的兜底
    private let fallbackPaths: [String]

    private var offset: UInt64 = 0
    private var carry = Data()
    private var initialized = false

    private var rounds = 0
    private var durations: [Double] = []
    private var startedAt: Date? = nil
    private var adopted = false            // 观察开始时就已经在跑的那轮：耗时是下界，不进平均
    private var step = 0
    private var stepTotal = 0
    private var lastFrames: Int? = nil
    private var lastSize: String? = nil
    private var lastAt: Date? = nil
    private var lastError = ""
    /// 首次扫描（界面启动时补读历史）：这段里看到的一轮没有可信起点，只计轮次不计耗时
    private var scanningInitial = false

    private let reStart = try! NSRegularExpression(
        pattern: #"\[[a-z0-9_-]+\] \d+x\d+ (\d+) frames? \((?:[^)]*)\), (\d+) steps"#)
    private let reStep = try! NSRegularExpression(pattern: #"\] step (\d+)/(\d+) sigma"#)
    private let reDone = try! NSRegularExpression(pattern: #"\[video\] -> (\d+)f (\d+)x(\d+)"#)

    init(kind: MediaKind, logPath: String?, port: Int?) {
        self.kind = kind
        var cands: [String] = []
        if let p = port, p > 0 { cands.append("~/.mlx-serve/logs/mlx-serve-\(p).log".expandingTildePath) }
        if let p = logPath { cands.append(p) }
        path = cands.first ?? ""
        fallbackPaths = Array(cands.dropFirst())
    }

    private var activePath: String { path }

    func refresh(now: Date) -> MediaMetric? {
        guard readTail(now: now) else { return nil }
        var out = MediaMetric(kind: kind)
        out.rounds = rounds
        out.durations = durations
        out.currentStep = startedAt == nil ? nil : step
        out.currentStepTotal = startedAt == nil ? nil : stepTotal
        if let st = startedAt {
            out.currentElapsedS = now.timeIntervalSince(st)
            out.currentIndex = rounds + 1
        }
        out.lastFrames = lastFrames
        out.lastSize = lastSize
        out.lastAt = lastAt
        out.source = "mlx-serve 日志（自本次启动）"
        var notes: [String] = []
        if adopted { notes.append("观察开始时本轮已在跑，耗时只按下界计（不计入平均）") }
        if startedAt != nil { notes.append("按日志出现时刻记时，误差 ≤ 一个轮询周期") }
        if !lastError.isEmpty { notes.append(lastError) }
        out.note = notes.joined(separator: "；")
        return out
    }

    // ---- 增量读日志（与 RuntimeMetrics 的 LogAggregator 同套路，但认的是「产物边界」）
    private func readTail(now: Date) -> Bool {
        var target = activePath
        if !FileManager.default.fileExists(atPath: target) {
            target = fallbackPaths.first { FileManager.default.fileExists(atPath: $0) } ?? target
        }
        guard !target.isEmpty, let fh = FileHandle(forReadingAtPath: target) else {
            lastError = "日志不可读（\(target.isEmpty ? "未配置路径" : target)）"
            return false
        }
        defer { try? fh.close() }
        lastError = ""
        let size = (try? fh.seekToEnd()) ?? 0
        if !initialized || size < offset {
            // 首次 / 日志轮转：从最后一个会话开始标记之后读
            resetSession()
            offset = findSessionStart(file: fh, size: size)
            carry = Data()
            initialized = true
            scanningInitial = true
            scan(file: fh, from: offset, to: size, now: now)
            scanningInitial = false
            offset = size
            // 首次扫描结束时仍在跑的这轮：起点早于我们的观察 ⇒ 只当下界
            if startedAt != nil { adopted = true }
            return true
        }
        guard size > offset else { return true }
        scan(file: fh, from: offset, to: size, now: now)
        offset = size
        return true
    }

    private func resetSession() {
        rounds = 0
        durations = []
        startedAt = nil
        adopted = false
        step = 0
        stepTotal = 0
        lastFrames = nil
        lastSize = nil
        lastAt = nil
    }

    private func scan(file: FileHandle, from: UInt64, to: UInt64, now: Date) {
        let want = Int(min(UInt64(16 << 20), to - from))
        guard want > 0 else { return }
        try? file.seek(toOffset: from)
        guard let chunk = try? file.read(upToCount: want), !chunk.isEmpty else { return }
        var data = carry
        data.append(chunk)
        carry = Data()
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<nl]
            data = data[(nl + 1)...]
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            consume(line, now: now)
        }
        if !data.isEmpty { carry = Data(data) }
    }

    private func consume(_ line: String, now: Date) {
        // 会话开始：引擎重新监听 ⇒ 之前的轮次不算这一趟
        if line.contains("Listening on 0.0.0.0:") || line.contains("Listening on 127.0.0.1:") {
            resetSession()
            return
        }
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: line) else { return nil }
            return String(line[r])
        }
        if let m = reStart.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            // 新一轮开始（chain 的每一窗也算一轮：每窗出一段片子）
            if startedAt == nil {
                startedAt = now
                step = 0
                adopted = scanningInitial          // 历史轮次没有可信起点
            }
            if let t = g(m, 2).flatMap({ Int($0) }) { stepTotal = t }
            step = 0
            return
        }
        if let m = reStep.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let d = g(m, 1).flatMap({ Int($0) }) { step = d }
            if let t = g(m, 2).flatMap({ Int($0) }) { stepTotal = t }
            return
        }
        if let m = reDone.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let st = startedAt {
                let dur = now.timeIntervalSince(st)
                rounds += 1
                if !adopted, dur > 0.05 { durations.append(dur) }
            }
            startedAt = nil
            adopted = false
            step = 0
            lastFrames = g(m, 1).flatMap { Int($0) }
            if let w = g(m, 2), let h = g(m, 3) { lastSize = w + "×" + h }
            lastAt = now
            return
        }
        if line.contains("[video] generation cancelled") {
            startedAt = nil
            adopted = false
            step = 0
            lastError = "上一轮被取消（客户端断开），未计入轮次"
        }
    }

    /// 自检钩子：直接喂一行引擎日志（等价于从文件里读到的那一行），不依赖引擎在跑
    func feedForTest(_ line: String, now: Date = Date(), adoptAsHistorical: Bool = false) {
        scanningInitial = adoptAsHistorical
        consume(line, now: now)
        scanningInitial = false
    }

    func snapshotForTest(at now: Date = Date()) -> MediaMetric {
        var out = MediaMetric(kind: kind)
        out.rounds = rounds
        out.durations = durations
        out.currentElapsedS = startedAt.map { now.timeIntervalSince($0) }
        out.currentStep = startedAt == nil ? nil : step
        out.currentStepTotal = startedAt == nil ? nil : stepTotal
        out.lastFrames = lastFrames
        out.lastSize = lastSize
        return out
    }

    /// 往回找最后一个「引擎开始监听」的行，返回该行之后的位置
    private func findSessionStart(file: FileHandle, size: UInt64) -> UInt64 {
        let chunkSize: UInt64 = 1 << 20
        let maxScan: UInt64 = 32 << 20
        var hi = size
        var scanned: UInt64 = 0
        while hi > 0 && scanned < maxScan {
            let lo = hi > chunkSize ? hi - chunkSize : 0
            try? file.seek(toOffset: lo)
            guard let data = try? file.read(upToCount: Int(hi - lo)), !data.isEmpty else { break }
            var searchEnd = data.endIndex
            while searchEnd > data.startIndex {
                let slice = data[data.startIndex..<searchEnd]
                guard let nl = slice.lastIndex(of: 0x0A) else { break }
                let lineData = data[(nl + 1)..<searchEnd]
                if let line = String(data: lineData, encoding: .utf8),
                   line.contains("Listening on 0.0.0.0:") || line.contains("Listening on 127.0.0.1:") {
                    let lineStart = data.distance(from: data.startIndex, to: nl) + 1
                    return lo + UInt64(lineStart)
                }
                searchEnd = nl
            }
            scanned += (hi - lo)
            hi = lo
        }
        return size > (1 << 20) ? size - (1 << 20) : 0
    }
}

// ============================================================
// MARK: - 探针仓库（按来源 + 端口/路径缓存：offset 与计时状态要跨轮保留）
// ============================================================

final class MediaMetricsStore {
    private var probes: [String: MediaProbe] = [:]

    func probe(for recipe: LaunchRecipe, port: Int?) -> MediaProbe? {
        guard let source = recipe.media?.lowercased(), !source.isEmpty else { return nil }
        let kind: MediaKind = {
            switch (recipe.category ?? "").lowercased() {
            case "video": return .video
            case "image": return .image
            default: return source.contains("comfy") ? .image : .video
            }
        }()
        let p = port ?? recipe.port ?? 0
        switch source {
        case "comfyui", "comfy":
            guard p > 0 else { return nil }
            let key = "comfyui:\(p)"
            if let probe = probes[key] { return probe }
            let probe = ComfyMediaProbe(port: p)
            probes[key] = probe
            return probe
        case "mlxserve", "mlx-serve", "mlxserve-log":
            let logPath = recipe.log
            let key = "mlxserve:\(logPath ?? "")|\(p)"
            if let probe = probes[key] { return probe }
            let probe = MlxServeMediaProbe(kind: kind, logPath: logPath, port: p)
            probes[key] = probe
            return probe
        default:
            return nil
        }
    }
}

// ============================================================
// MARK: - 文案（界面与 CLI 共用，口径只写一份）
// ============================================================

/// 耗时文案：< 10 秒给一位小数，< 100 秒取整，再长按分秒
func mediaSeconds(_ s: Double) -> String {
    if s < 0 { return "—" }
    if s < 10 { return String(format: "%.1f 秒", s) }
    if s < 100 { return String(format: "%.0f 秒", s) }
    if s < 3600 {
        let m = Int(s) / 60
        return "\(m) 分 \(Int(s) % 60) 秒"
    }
    return prettyUptime(s)
}

/// 每轮耗时（带一位小数，便于比较 43.7 / 44.6 这种差别）
func mediaRoundSeconds(_ s: Double) -> String {
    s < 100 ? String(format: "%.1f 秒", s) : String(format: "%.0f 秒", s)
}

/// 平均值的口径说明：观测到的轮次少于总轮次时，注明是按几轮算的
/// （媒体引擎重启后补读的历史轮次没有可信起点，只计轮次不计耗时）
func mediaMeasuredTag(_ m: MediaMetric) -> String {
    let n = m.durations.count
    return (n > 0 && n < m.rounds) ? "（观测 \(n) 轮）" : ""
}

/// 一行式摘要（运行时行 / 管理器卡片 / CLI 共用）
func mediaSummaryLine(_ m: MediaMetric) -> [String] {
    var bits: [String] = []
    let u = m.kind.unit
    if m.rounds > 0 {
        if let p = m.products, p > m.rounds {
            bits.append("已出 \(m.rounds) 轮 · \(p) \(u)")     // 一轮批量出了多张
        } else {
            bits.append("已出 \(m.rounds) \(u)")
        }
        if let a = m.avgS {
            bits.append("平均 " + mediaRoundSeconds(a) + "/" + u + mediaMeasuredTag(m))
        } else {
            bits.append("耗时未观测")
        }
    } else if !m.isBusy {
        bits.append(m.kind.idleVerb)
    }
    if let el = m.currentElapsedS {
        var cur = "当前第 \(m.currentIndex ?? m.rounds + 1) \(u) " + mediaSeconds(el)
        if let d = m.currentStep, let t = m.currentStepTotal, t > 0 { cur += "（\(d)/\(t) 步）" }
        bits.append(cur)
    } else if m.rounds > 0 {
        bits.append("空闲")
    }
    if m.queued > 0 { bits.append("队列 \(m.queued)") }
    return bits
}

/// 管理器卡片上的紧凑一行（窄，只留必要项）
func mediaCompactLine(_ m: MediaMetric) -> [String] {
    var bits: [String] = []
    let u = m.kind.unit
    if m.rounds > 0 {
        bits.append("\(m.rounds) \(u)")
        if let a = m.avgS { bits.append(mediaRoundSeconds(a) + "/" + u + mediaMeasuredTag(m)) }
    } else if !m.isBusy {
        bits.append(m.kind.idleVerb)
    }
    if let el = m.currentElapsedS {
        bits.append("当前 " + mediaSeconds(el))
        if let d = m.currentStep, let t = m.currentStepTotal, t > 0 { bits.append("\(d)/\(t) 步") }
    } else if m.rounds > 0 {
        bits.append("空闲")
    }
    return bits
}

/// 展开区的两三行细节
func mediaDetailLines(_ m: MediaMetric) -> [String] {
    var out: [String] = []
    let u = m.kind.unit
    if let el = m.currentElapsedS {
        var line = "当前：第 \(m.currentIndex ?? m.rounds + 1) \(u) · 已用 " + mediaSeconds(el)
        if let d = m.currentStep, let t = m.currentStepTotal, t > 0 { line += " · 步 \(d)/\(t)" }
        if m.queued > 0 { line += "　｜　队列还有 \(m.queued) 个" }
        out.append(line)
    } else {
        out.append("当前没有任务" + (m.queued > 0 ? "（队列里还有 \(m.queued) 个）" : ""))
    }
    var stats: [String] = []
    if let l = m.lastS { stats.append("最近一轮 " + mediaRoundSeconds(l)) }
    if let lo = m.minS, let hi = m.maxS, m.durations.count >= 2 {
        stats.append("最快 " + mediaRoundSeconds(lo) + " / 最慢 " + mediaRoundSeconds(hi))
    }
    if stats.isEmpty {
        stats.append(m.rounds > 0
            ? "本次启动 \(m.rounds) \(u)，但耗时未观测到（界面启动晚于这些轮次）"
            : "本次启动" + m.kind.idleVerb)
    }
    var spec: [String] = []
    if let f = m.lastFrames { spec.append("\(f) 帧") }
    if let s = m.lastSize { spec.append(s) }
    if !spec.isEmpty { stats.append("上一条 " + spec.joined(separator: " · ")) }
    out.append(stats.joined(separator: "　｜　"))
    var src = "数据来源：" + (m.source.isEmpty ? "未配置" : m.source)
    if !m.note.isEmpty { src += "　｜　" + m.note }
    out.append(src)
    return out
}
