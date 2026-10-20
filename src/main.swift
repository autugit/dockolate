// DockStats — 在 Dock 图标与菜单栏实时显示 CPU / GPU / 内存占用率
// 采样全部走本机公开接口：host_processor_info / host_statistics64 / ioreg(IOAccelerator)
// 无第三方依赖，无 root 需求。

import Cocoa
import Darwin

// ============================================================
// MARK: - 采样模型
// ============================================================

struct Sample {
    var cpu: Double = 0            // 0...100
    var gpu: Double? = nil         // 0...100，nil = 本次读不到
    var memPct: Double = 0         // 0...100（应用 + 联动 + 压缩，活动监视器口径）
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
    // 内存分解（GB）—— 用来解释「为什么进程榜加起来远小于总量」
    var memAppGB: Double = 0          // 匿名/应用内存
    var memWiredGB: Double = 0        // 内核联动
    var memCompressedGB: Double = 0   // 压缩器占用
    var memCachedGB: Double = 0       // 文件缓存（可回收，不计入已用）
    var memFreeGB: Double = 0
    var memPressurePct: Double = 0    // (压缩 + 换页) ÷ 物理内存 —— 内存真正紧张的程度
    var swapUsedGB: Double = 0
}

// ============================================================
// MARK: - CPU（host_processor_info 增量法，全核聚合）
// ============================================================

final class CPUSampler {
    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0

    private func ticks() -> (busy: UInt64, total: UInt64)? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info = info, infoCount > 0 else { return nil }
        defer {
            let addr = vm_address_t(UInt(bitPattern: info))
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, addr, size)
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            guard base + stride <= Int(infoCount) else { break }
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let sys  = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            busy  += user &+ sys &+ nice
            total += user &+ sys &+ idle &+ nice
        }
        return (busy, total)
    }

    /// 首次调用返回 nil（无基准），之后返回两次采样之间的占用率
    func next() -> Double? {
        guard let t = ticks() else { return nil }
        defer { prevBusy = t.busy; prevTotal = t.total }
        guard prevTotal > 0, t.total > prevTotal else { return nil }
        let dBusy = Double(t.busy &- prevBusy)
        let dTotal = Double(t.total - prevTotal)
        guard dTotal > 0 else { return nil }
        return min(100, max(0, dBusy / dTotal * 100))
    }
}

// ============================================================
// MARK: - 内存（host_statistics64）
// 口径：已用 = 活跃 + 已占用(wired) + 压缩器占用页
//       —— 与「活动监视器」的 已用内存 ≈ App 内存 + 联动 + 已压缩 对齐；
//          inactive/speculative/free 视为可回收，不计入已用。
// ============================================================

struct MemBreakdown {
    var appGB: Double = 0
    var wiredGB: Double = 0
    var compressedGB: Double = 0
    var cachedGB: Double = 0
    var freeGB: Double = 0
    var totalGB: Double = 0
}

final class MemorySampler {
    private let totalBytes: Double
    private var pageSize: Double = 16384
    private(set) var last = MemBreakdown()

    init() {
        totalBytes = Double(MemorySampler.sysctlU64("hw.memsize"))
        var ps: vm_size_t = 0
        if host_page_size(mach_host_self(), &ps) == KERN_SUCCESS, ps > 0 {
            pageSize = Double(ps)
        }
    }

    private static func sysctlU64(_ name: String) -> UInt64 {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size == MemoryLayout<UInt64>.size else { return 0 }
        var v: UInt64 = 0
        var s = size
        guard sysctlbyname(name, &v, &s, nil, 0) == 0 else { return 0 }
        return v
    }

    func next() -> (pct: Double, usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &stats) { sp in
            sp.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return (0, 0, totalBytes / 1_073_741_824)
        }
        let G = 1_073_741_824.0
        // 活动监视器口径：已用 = 应用内存(匿名页) + 联动(wired) + 压缩器占用。
        // 注意：不能用 active_count —— 它混进了大量 file-backed 页面（文件缓存），
        //       那部分随时可回收，算进「已用」会让占用率虚高几十 GB。
        let appPages = Double(stats.internal_page_count) * pageSize
        let wired    = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let cached   = Double(stats.external_page_count) * pageSize
        let freeB    = Double(stats.free_count) * pageSize
        let used = appPages + wired + compressed
        let pct = totalBytes > 0 ? min(100, used / totalBytes * 100) : 0
        self.last = MemBreakdown(appGB: appPages / G, wiredGB: wired / G,
                                 compressedGB: compressed / G, cachedGB: cached / G,
                                 freeGB: freeB / G, totalGB: totalBytes / G)
        return (pct, used / G, totalBytes / G)
    }
}

// ============================================================
// MARK: - GPU 采样
// ============================================================
//
// 不用 IOAccelerator 的 "Device Utilization %"：实测该字段会假报 0
// （Metal 满载压测期间仍偶尔读出 0，低负载时长期为 0），不可信。
// 改用各 GPU 客户端累计时间之和求差，稳定且与 per-process 榜同源：
//   占用率 = Σ(所有 AGXDeviceUserClient 的 accumulatedGPUTime 增量) ÷ 墙钟

/// 解析 `ioreg -c AGXDeviceUserClient` 的输出。
/// 每个客户端实例的 `IOUserClientCreator` 是持有进程，
/// `AppUsage` 里累计该客户端的 GPU 时间（纳秒）。
func parseGPUClients(_ text: String) -> (total: Int, byPid: [Int32: (name: String, t: Int)]) {
    var total = 0
    var byPid: [Int32: (name: String, t: Int)] = [:]
    for b in text.components(separatedBy: "+-o AGXDeviceUserClient").dropFirst() {
        guard let r = b.range(of: "\"IOUserClientCreator\" = \"pid "),
              let comma = b[r.upperBound...].firstIndex(of: ","),
              let pid = Int32(b[r.upperBound..<comma]) else { continue }
        let afterComma = b[b.index(after: comma)...]
        guard let q = afterComma.firstIndex(of: "\"") else { continue }
        let name = String(afterComma[..<q]).trimmingCharacters(in: .whitespaces)

        var t = 0
        var idx = b.startIndex
        while let rr = b.range(of: "\"accumulatedGPUTime\"=", range: idx..<b.endIndex) {
            let digits = b[rr.upperBound...].prefix(while: { $0.isNumber })
            if let v = Int(digits) { t += v }
            if digits.endIndex <= rr.upperBound { break }
            idx = digits.endIndex
        }
        total += t
        let prev = byPid[pid]
        byPid[pid] = (prev?.name ?? name, (prev?.t ?? 0) + t)
    }
    return (total, byPid)
}

func readGPUClientTimes() -> (total: Int, byPid: [Int32: (name: String, t: Int)])? {
    guard let text = ProcessSampler.run("/usr/sbin/ioreg",
            ["-r", "-c", "AGXDeviceUserClient", "-l", "-w", "0"]) else { return nil }
    return parseGPUClients(text)
}

final class GPUSampler {
    private var prevTotal: Int?
    private var prevAt = Date()
    private var cached: Double?
    private let interval: TimeInterval = 2.0

    func next() -> Double? {
        let now = Date()
        let dt = now.timeIntervalSince(prevAt)
        guard dt >= interval else { return cached }
        guard let cur = readGPUClientTimes()?.total else { return cached }

        prevAt = now
        let prev = prevTotal
        prevTotal = cur

        guard let prev = prev, dt > 0.2 else { return cached }   // 首拍只建基准
        let delta = cur - prev
        guard delta >= 0 else { return cached }
        cached = min(100, Double(delta) / (dt * 1_000_000_000) * 100)
        return cached
    }

    /// 建立基准（启动时用，避免首屏空白太久）
    func prime() { prevTotal = readGPUClientTimes()?.total; prevAt = Date() }
}

// ============================================================
// MARK: - 当前实际运行的 GPU 名称（用于详情窗口）
// ============================================================

func gpuName() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPDisplaysDataType", "-detailLevel", "mini"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "GPU" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return "GPU" }
    for line in text.split(separator: "\n") {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("Chipset Model:") {
            return l.replacingOccurrences(of: "Chipset Model:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }
    return "GPU"
}

// ============================================================
// MARK: - 配色：占用率 → 颜色
// ============================================================

func levelColor(_ pct: Double) -> NSColor {
    switch pct {
    case ..<20:  return NSColor(calibratedRed: 0.32, green: 0.62, blue: 0.98, alpha: 1)  // 蓝 · 极低
    case ..<50:  return NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)  // 绿 · 低
    case ..<80:  return NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1)  // 黄 · 中
    default:     return NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.28, alpha: 1)  // 红 · 高
    }
}

// ============================================================
// MARK: - 换页量（sysctl vm.swapusage，C 接口，非子进程）
// ============================================================

struct XswUsage {
    var total: UInt64 = 0
    var avail: UInt64 = 0
    var used: UInt64 = 0
    var pagesize: UInt32 = 0
    var encrypted: UInt8 = 0
}

func swapUsedGB() -> Double {
    var u = XswUsage()
    var size = MemoryLayout<XswUsage>.stride
    guard sysctlbyname("vm.swapusage", &u, &size, nil, 0) == 0 else { return 0 }
    return Double(u.used) / 1_073_741_824
}

// ============================================================
// MARK: - Dock 图标绘制
// ============================================================

/// 水位格：底部往上填充，颜色随水位分级；大号字母水印压在最上层（白，任何水位下都清晰）
func drawWaterCell(_ r: NSRect, letter: String, pct: Double, color: NSColor) {
    let radius: CGFloat = 19
    let box = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

    // 槽底（未被填充的部分）
    NSColor(calibratedWhite: 0.15, alpha: 1.0).setFill()
    box.fill()

    // 水位：从下往上，裁到格子圆角内
    let frac = CGFloat(min(100, max(0, pct)) / 100.0)
    if frac > 0.002 {
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        let h = r.height * frac
        let water = NSRect(x: r.minX, y: r.minY, width: r.width, height: h)
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(rect: water).fill()
        // 水面高光：一条细亮线，让"水位"有刻度感
        NSColor(calibratedWhite: 1.0, alpha: 0.35).setFill()
        NSBezierPath(rect: NSRect(x: r.minX, y: r.minY + h - 1.5,
                                  width: r.width, height: 1.5)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // 大号字母水印：白，压在水位之上，永远可辨
    NSGraphicsContext.saveGraphicsState()
    box.addClip()
    // 白字 + 极淡暗描边：水位是彩色时纯白字会"糊"进底色，描边把它钉住
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: r.height * 0.92, weight: .black),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.56),
        .strokeColor: NSColor(calibratedWhite: 0.0, alpha: 0.40),
        .strokeWidth: -2.5,
    ]
    let sz = (letter as NSString).size(withAttributes: attrs)
    (letter as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2),
                              withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()

    // 描边
    color.withAlphaComponent(0.65).setStroke()
    box.lineWidth = 2
    box.stroke()
}

// MARK: Dock 图标（256×256 四宫格：左上 C · 右上 G · 左下 M · 右下 Z）
// 顺序按「主指标先读」排：上排 C/G（算力），下排 M「用了多少」在前、Z「被挤压多少」在后，
// 与菜单栏读数 C→G→M、窗口里 Z 明细行的阅读顺序一致。
func makeDockIcon(_ s: Sample) -> NSImage {
    let side: CGFloat = 256
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 54, yRadius: 54)
        NSColor(calibratedWhite: 0.085, alpha: 1.0).setFill()
        bg.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.11).setStroke()
        bg.lineWidth = 2
        bg.stroke()

        let margin: CGFloat = 24
        let gap: CGFloat = 12
        let inner = side - margin * 2
        let cellW = (inner - gap) / 2
        let cellH = cellW
        let leftX = margin
        let rightX = margin + cellW + gap
        let topY = side - margin - cellH
        let botY = margin

        // 左上 CPU
        drawWaterCell(NSRect(x: leftX, y: topY, width: cellW, height: cellH),
                      letter: "C", pct: s.cpu, color: levelColor(s.cpu))

        // 右上 GPU（读不到时灰色空水位）
        let g = s.gpu
        drawWaterCell(NSRect(x: rightX, y: topY, width: cellW, height: cellH),
                      letter: "G", pct: g ?? 0,
                      color: g == nil ? NSColor(calibratedWhite: 0.45, alpha: 1) : levelColor(g!))

        // 左下 M：内存占用
        drawWaterCell(NSRect(x: leftX, y: botY, width: cellW, height: cellH),
                      letter: "M", pct: s.memPct, color: levelColor(s.memPct))

        // 右下 Z：内存压缩 + 换页
        drawWaterCell(NSRect(x: rightX, y: botY, width: cellW, height: cellH),
                      letter: "Z", pct: s.memPressurePct, color: levelColor(s.memPressurePct))

        return true
    }
    return img
}

// ============================================================
// MARK: - 菜单栏视图（读数字符串 + 点击弹出菜单）
// ============================================================

final class StatusItemController {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    func update(_ s: Sample) {
        guard let button = item.button else { return }
        let gpu = s.gpu.map { String(format: "%.0f", $0) } ?? "–"
        let text = String(format: "C%.0f G%@ M%.0f", s.cpu, gpu, s.memPct)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: "C", attributes: [.font: monoFont,
                                                              .foregroundColor: levelColor(s.cpu)]))
        a.append(NSAttributedString(string: String(format: "%.0f ", s.cpu), attributes: attrs))
        a.append(NSAttributedString(string: "G", attributes: [.font: monoFont,
                                                              .foregroundColor: levelColor(s.gpu ?? 0)]))
        a.append(NSAttributedString(string: "\(gpu) ", attributes: attrs))
        a.append(NSAttributedString(string: "M", attributes: [.font: monoFont,
                                                              .foregroundColor: levelColor(s.memPct)]))
        a.append(NSAttributedString(string: String(format: "%.0f", s.memPct), attributes: attrs))
        button.attributedTitle = a
        button.toolTip = String(format: "CPU %.1f%%　GPU %@　内存 %.1f%%（%.1f / %.0f GB）",
                                s.cpu,
                                s.gpu.map { String(format: "%.1f%%", $0) } ?? "不可读",
                                s.memPct, s.memUsedGB, s.memTotalGB)
        let _ = text
    }
}

// ============================================================
// MARK: - 进程排行采样（点击 Dock 图标时的窗口）
// ============================================================

struct ProcStat {
    let pid: Int32
    let name: String
    let value: Double      // CPU: % ／ 内存: bytes ／ GPU: % of one GPU-second
}

final class ProcessSampler {

    // ---------- 通用子进程 ----------
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func shortName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }

    // ---------- CPU / 内存：ps ----------
    private func psTop(_ n: Int, sortFlag: String, valueKey: String) -> [ProcStat] {
        guard let out = ProcessSampler.run("/bin/ps",
                ["-A", "-o", "pid=,\(valueKey)=,comm=", sortFlag]) else { return [] }
        var res: [ProcStat] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let v = Double(parts[1]) else { continue }
            res.append(ProcStat(pid: pid, name: ProcessSampler.shortName(String(parts[2])), value: v))
            if res.count >= n { break }
        }
        return res
    }

    func topCPU(_ n: Int = 3) -> [ProcStat] {
        psTop(n, sortFlag: "-r", valueKey: "pcpu")           // -r: 按 CPU 降序
    }

    /// 内存占用：phys_footprint（活动监视器同款口径），走 libproc 而非 ps。
    /// 为什么不用 ps 的 rss：实测对 mmap 大户会少报一个数量级
    /// （Python 进程真实 23 GB，ps rss 只报 0.97 GB；python3.11 真实 18 GB，ps 几乎不显示）。
    func topMemory(_ n: Int = 3) -> [ProcStat] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(pids.count * MemoryLayout<pid_t>.stride))
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        guard count > 0 else { return [] }

        var rows: [ProcStat] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = rusage_info_current()
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rp)
                }
            }
            guard kr == 0 else { continue }
            let fp = info.ri_phys_footprint
            guard fp > 0 else { continue }
            var nameBuf = [CChar](repeating: 0, count: 1024)
            let nameLen = proc_name(pid, &nameBuf, 1024)
            let nm = nameLen > 0 ? String(cString: nameBuf) : "pid \(pid)"
            rows.append(ProcStat(pid: pid, name: nm, value: Double(fp)))
        }
        rows.sort { $0.value > $1.value }
        return Array(rows.prefix(n))
    }

    // ---------- GPU：AGXDeviceUserClient 的 accumulatedGPUTime 增量 ----------
    // 每个 GPU 用户客户端实例的 IOUserClientCreator 就是持有进程，
    // AppUsage 里累积了该客户端的 GPU 时间（纳秒）。
    // 两次采样求差 ÷ 墙钟 ⇒ 该进程占用了多少个「整颗 GPU」的算力。
    private var gpuPrev: [Int32: (name: String, t: Int)] = [:]
    private var gpuPrevAt = Date()
    private var gpuCached: [ProcStat] = []

    private func readGPUclients() -> [Int32: (name: String, t: Int)] {
        readGPUClientTimes()?.byPid ?? [:]
    }

    /// 换页情况：vm.swapusage（窗口打开时才查，图标不显示）
    func swapUsage() -> (usedGB: Double, totalGB: Double) {
        guard let out = ProcessSampler.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]) else {
            return (0, 0)
        }
        func value(_ key: String) -> Double {
            guard let r = out.range(of: "\(key) = ") else { return 0 }
            let rest = out[r.upperBound...]
            let num = rest.prefix { $0.isNumber || $0 == "." }
            guard let v = Double(num), num.endIndex < rest.endIndex else { return 0 }
            switch rest[num.endIndex] {
            case "G": return v
            case "M": return v / 1024
            case "K": return v / 1_048_576
            default:  return v / 1_073_741_824
            }
        }
        return (value("used"), value("total"))
    }

    func topGPU(_ n: Int = 3) -> [ProcStat] {
        let now = Date()
        let cur = readGPUclients()
        let dt = now.timeIntervalSince(gpuPrevAt)
        defer { gpuPrev = cur; gpuPrevAt = now }
        guard !gpuPrev.isEmpty, dt > 0.2 else { return gpuCached }

        var res: [ProcStat] = []
        for (pid, v) in cur {
            guard let old = gpuPrev[pid] else { continue }
            let d = v.t - old.t
            guard d > 0 else { continue }
            res.append(ProcStat(pid: pid, name: ProcessSampler.shortName(v.name),
                                value: Double(d) / (dt * 1_000_000_000) * 100))
        }
        res.sort { $0.value > $1.value }
        gpuCached = Array(res.prefix(n))
        return gpuCached
    }
}

// ============================================================
// MARK: - 本机 AI 模型（窗口里的「模型」一栏）
// ============================================================
//
// 两路数据各管一件事，缺一不可：
//   ① 进程侧（libproc）—— 谁真的占着内存、监听哪个端口、有没有在算；
//   ② 网关侧（127.0.0.1:8010/v1/models）—— 本机声明了哪几个模型、哪些常驻在哪个端口。
// 只看 ① 会把「配置里有、但没加载」的模型藏掉，也认不出模型名（oMLX 会改写自己的 argv，
// 进程名只剩 python3.11）；只看 ② 会把崩掉的服务当成正常。所以两边交叉。
//
// 状态口径（窗口里逐行显示）：
//   正在运行 —— 进程在、端口在监听、最近 12 秒内有计算（CPU 或 GPU 时间在涨）
//   挂载待机 —— 进程在、端口在监听、这段时间没算过东西（权重仍占着内存）
//   出现故障 —— 声明为常驻却连不上端口；或进程在却不监听任何端口
//   未加载   —— 网关声明存在但没常驻（不占内存 ⇒ 不进排序，单独一行列出）

enum ModelState {
    case running, idle, failed, unloaded

    var text: String {
        switch self {
        case .running:  return "正在运行"
        case .idle:     return "挂载待机"
        case .failed:   return "出现故障"
        case .unloaded: return "未加载"
        }
    }

    var color: NSColor {
        switch self {
        case .running:  return NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)  // 绿
        case .idle:     return NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.95, alpha: 1)  // 蓝
        case .failed:   return NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.28, alpha: 1)  // 红
        case .unloaded: return .tertiaryLabelColor
        }
    }
}

struct ModelRow {
    var name: String
    var memGB: Double
    var state: ModelState
    var note: String
    var pid: pid_t? = nil     // 仅内部用：判定「一个进程托管多个模型 ⇒ 内存是合计」
    var shared: Bool = false
}

struct ModelSnapshot {
    var rows: [ModelRow] = []
    var unloaded: [String] = []
    var gatewayUp = false
    var hiddenRows = 0
}

/// 网关 /v1/models 里声明的一条
private struct GatewayModel {
    var id: String
    var port: Int
    var resident: Bool
}

/// 扫描到的模型服务进程
private struct ModelProc {
    var pid: pid_t
    var kind: String
    var display: String
    var memBytes: UInt64
    var cpuNs: UInt64
    var ports: [Int]
}

final class LocalModelSampler {
    /// 本地模型网关端口（--gateway= 可覆盖，验收时用来喂假声明）
    var gatewayPort = 8010
    private let activeWindow: TimeInterval = 12     // 最近多少秒算过东西 ⇒ 正在运行
    private let activeThreshold: TimeInterval = 0.03 // 2 秒窗口内 30 ms 计算量即算"在算"

    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevGPU: [pid_t: Int] = [:]
    private var prevAt = Date()
    private var lastActive: [pid_t: Date] = [:]

    // ---------- 一、进程识别 ----------
    /// (关键字, 归属) —— 顺序敏感：先命中先算
    /// 语言模型服务在前，生图/视频引擎在后（关键词越具体的越靠前，否则 "comfy" 会被别的路径抢走）
    private let kindHints: [(String, String)] = [
        ("omlx", "oMLX"),
        ("llama-server", "llama.cpp"), ("llama_server", "llama.cpp"), ("llama.cpp", "llama.cpp"),
        ("mlx_lm.server", "MLX"), ("mlx_vlm.server", "MLX"), ("mlx-lm", "MLX"), ("mlx_vlm", "MLX"),
        ("ollama", "Ollama"),
        ("lmstudio", "LM Studio"), ("lm studio", "LM Studio"),
        ("vllm", "vLLM"), ("sglang", "SGLang"),
        // 生图 / 视频 / 换脸引擎
        ("comfyui", "ComfyUI"), ("comfy", "ComfyUI"),
        ("draw things", "Draw Things"), ("drawthings", "Draw Things"), ("draw-things", "Draw Things"),
        ("mflux", "mflux"),
        ("fooocus", "Fooocus"), ("invokeai", "InvokeAI"), ("invoke-ai", "InvokeAI"),
        ("stable-diffusion.cpp", "sd.cpp"), ("sd-server", "sd.cpp"), ("sd-cli", "sd.cpp"),
        ("stable-diffusion-webui", "A1111"), ("webui.py", "A1111"),
        ("diffusers", "Diffusers"),
        ("qwen-image", "Qwen-Image"), ("qwen_image", "Qwen-Image"),
        ("flux", "Flux"),
    ]
    /// 先按进程名/路径快速筛，避免对 780 个进程挨个 sysctl 读 argv
    private let quickHints = ["omlx", "llama", "mlx", "ollama", "lmstudio", "lm studio", "vllm", "sglang",
                              "comfy", "draw things", "drawthings", "mflux", "fooocus", "invokeai",
                              "stable-diffusion", "sd-server", "diffusers", "qwen-image", "qwen_image"]
    private let interpreters = ["python", "python3", "node", "ruby", "java", "uv", "uvicorn"]

    /// 已知的推理服务端口 → 引擎名。用于「解释器进程 + 端口对得上」这种认不出模型名的场景
    /// （ComfyUI 就是这样：进程叫 Python，argv 只有 main.py --port 8188）。
    private let portEngines: [Int: String] = [
        8188: "ComfyUI",
        7860: "Draw Things / A1111",
        7861: "A1111",
        8189: "ComfyUI",
        8888: "Fooocus",
        9090: "InvokeAI",
    ]

    private func classify(name: String, path: String, argv: [String]) -> String? {
        let head = argv.first ?? ""
        let hay = (name + " " + path + " " + head).lowercased()
        for (k, v) in kindHints where hay.contains(k) { return v }
        return nil
    }

    /// 模型名：优先 argv 里的 --model / -m 等；不够再退回「归属 + 端口」
    private func modelDisplay(argv: [String], kind: String) -> String {
        let flags = ["--model", "-m", "--model-path", "--model-dir", "--hf-repo", "--model-id", "--repo-id"]
        for (i, a) in argv.enumerated() {
            if flags.contains(a), i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
                let base = (argv[i + 1] as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
            for f in flags where a.hasPrefix(f + "=") {
                let base = (String(a.dropFirst(f.count + 1)) as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
        }
        for a in argv where a.hasSuffix(".gguf") {
            return ((a as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return kind
    }

    // ---------- 二、进程数据 ----------
    private func argvOf(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        var idx = 4
        while idx < size && buf[idx] != 0 { idx += 1 }   // 跳过可执行路径
        while idx < size && buf[idx] == 0 { idx += 1 }   // 跳过填充
        var out: [String] = []
        var n: Int32 = 0
        while n < argc && idx < size {
            var end = idx
            while end < size && buf[end] != 0 { end += 1 }
            out.append(String(decoding: buf[idx..<end], as: UTF8.self))
            n += 1
            idx = end + 1
        }
        return out
    }

    private func rusageOf(_ pid: pid_t) -> (mem: UInt64, cpuNs: UInt64)? {
        var info = rusage_info_current()
        let kr = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rp)
            }
        }
        guard kr == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_user_time + info.ri_system_time)
    }

    /// 该进程处于 LISTEN 状态的 TCP 端口。
    /// 坑：macOS 27 内核的 struct socket_info 比 SDK 头文件大 24 字节（792 vs 768），
    /// 直接 cast 成 Swift 结构体会整体错位（读出的 soi_kind 是垃圾值）；
    /// 这里按「返回字节数 − 结构体大小」做偏移补偿，并用 soi_kind / soi_family 双重校验。
    private func listeningPorts(_ pid: pid_t) -> [Int] {
        let maxFD = 2048
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: maxFD)
        let sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                              Int32(maxFD * MemoryLayout<proc_fdinfo>.stride))
        guard sz > 0 else { return [] }
        let n = Int(sz) / MemoryLayout<proc_fdinfo>.stride
        var ports: [Int] = []
        for i in 0..<n {
            guard fds[i].proc_fdtype == 2 else { continue }   // PROX_FDTYPE_SOCKET
            var buf = [UInt8](repeating: 0, count: 2048)
            let r = buf.withUnsafeMutableBytes { raw -> Int32 in
                proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO,
                               raw.baseAddress, Int32(raw.count))
            }
            guard r > 0 else { continue }
            let shift = Int(r) - MemoryLayout<socket_info>.stride
            guard shift >= 0, shift <= 64 else { continue }

            func i32(_ off: Int) -> Int32 {
                let o = off + shift
                guard o >= 0, o + 4 <= buf.count else { return 0 }
                var v: Int32 = 0
                withUnsafeMutableBytes(of: &v) { dst in
                    buf.withUnsafeBytes { src in
                        dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[o..<o + 4]))
                    }
                }
                return v
            }

            guard i32(232) == 2,      // soi_kind == SOCKINFO_TCP
                  i32(160) == AF_INET || i32(160) == AF_INET6 else { continue }   // soi_family
            guard i32(320) == 1 else { continue }   // pri_tcp.tcpsi_state == TCPS_LISTEN
            // pri_in.insi_lport（网络字节序，存低 16 位）
            let raw = UInt16(truncatingIfNeeded: i32(244))
            ports.append(Int(raw.bigEndian))
        }
        return ports
    }

    // ---------- 三、端口探活 / 网关读取（原始 socket，不走系统代理）----------
    private func connectable(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    private func httpBody(port: Int, path: String) -> String? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: 600_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let cr = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard cr == 0 else { return nil }
        let req = "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nAccept: application/json\r\n\r\n"
        _ = req.withCString { write(s, $0, strlen($0)) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(s, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > 1024 * 1024 { break }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let r = text.range(of: "\r\n\r\n") else { return nil }
        return String(text[r.upperBound...])
    }

    private func gatewayModels() -> [GatewayModel]? {
        guard let body = httpBody(port: gatewayPort, path: "/v1/models"),
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return nil }
        var out: [GatewayModel] = []
        for m in arr {
            guard let id = m["id"] as? String else { continue }
            let local = m["local"] as? [String: Any] ?? [:]
            out.append(GatewayModel(id: id,
                                    port: (local["port"] as? Int) ?? 0,
                                    resident: (local["resident"] as? Bool) ?? false))
        }
        return out.isEmpty ? nil : out
    }

    // ---------- 四、一次完整采样 ----------
    func refresh() -> ModelSnapshot {
        let now = Date()
        var snap = ModelSnapshot()

        // 4.1 扫进程
        var procs: [ModelProc] = []
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(pids.count * MemoryLayout<pid_t>.stride))
        let count = max(0, Int(bytes) / MemoryLayout<pid_t>.stride)
        let selfPid = getpid()
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, pid != selfPid else { continue }
            var nameBuf = [CChar](repeating: 0, count: 1024)
            let nlen = proc_name(pid, &nameBuf, 1024)
            let pname = nlen > 0 ? String(cString: nameBuf) : ""
            var pathBuf = [CChar](repeating: 0, count: 4096)
            _ = proc_pidpath(pid, &pathBuf, 4096)
            let ppath = String(cString: pathBuf)

            let quick = (pname + " " + ppath).lowercased()
            let suspicious = quickHints.contains { quick.contains($0) }
                || interpreters.contains { pname.lowercased().hasPrefix($0) }
            guard suspicious else { continue }

            let argv = argvOf(pid)
            var kind = classify(name: pname, path: ppath, argv: argv)
            let ports = listeningPorts(pid)
            if kind == nil,
               let engine = ports.compactMap({ portEngines[$0] }).first,
               interpreters.contains(where: { pname.lowercased().hasPrefix($0) }) {
                kind = engine        // 认不出名字、但端口对得上已知引擎（ComfyUI 就是这种）
            }
            guard let kind = kind else { continue }
            guard let ru = rusageOf(pid) else { continue }
            // 有监听端口的服务不设内存门槛（权重可能 mmap/在子进程里，主进程本身可能只有几十 MB）；
            // 没有端口的（GUI 应用 / 库）要求真占着内存，避免把客户端壳子也算进来
            if ports.isEmpty && ru.mem < 300 * 1024 * 1024 { continue }
            procs.append(ModelProc(pid: pid, kind: kind,
                                   display: modelDisplay(argv: argv, kind: kind),
                                   memBytes: ru.mem, cpuNs: ru.cpuNs,
                                   ports: ports))
        }

        // 4.2 活动判定（CPU 或 GPU 时间在涨 ⇒ 正在算）
        let gpu = readGPUClientTimes()?.byPid ?? [:]
        var activeNow: Set<pid_t> = []
        for p in procs {
            let g = gpu[p.pid]?.t ?? 0
            defer { prevCPU[p.pid] = p.cpuNs; prevGPU[p.pid] = g }
            guard let oldCPU = prevCPU[p.pid] else { continue }   // 首拍只建基准
            let oldGPU = prevGPU[p.pid] ?? g
            let dCPU = Double(p.cpuNs >= oldCPU ? p.cpuNs - oldCPU : 0) / 1_000_000_000
            let dGPU = Double(max(0, g - oldGPU)) / 1_000_000_000
            if dCPU >= activeThreshold || dGPU >= activeThreshold { activeNow.insert(p.pid) }
        }
        for pid in activeNow { lastActive[pid] = now }
        // 清掉已经消失的进程的记录（先取快照再改，别边遍历边写字典）
        let alive = Set(procs.map { $0.pid })
        for pid in lastActive.keys.filter({ !alive.contains($0) }) { lastActive[pid] = nil }
        for pid in Set(prevCPU.keys).subtracting(alive) { prevCPU[pid] = nil; prevGPU[pid] = nil }

        func isRunning(_ pid: pid_t) -> Bool {
            guard let t = lastActive[pid] else { return false }
            return now.timeIntervalSince(t) <= activeWindow
        }

        // 4.3 合并网关声明
        let declared = gatewayModels()
        snap.gatewayUp = declared != nil
        var claimed: Set<pid_t> = []
        var pidUse: [pid_t: Int] = [:]

        func append(pid: pid_t?, name: String, mem: UInt64, state: ModelState, note: String) {
            if let p = pid { pidUse[p, default: 0] += 1 }
            snap.rows.append(ModelRow(name: name, memGB: Double(mem) / 1_073_741_824,
                                      state: state, note: note, pid: pid))
        }

        if let list = declared {
            for m in list {
                if !m.resident {
                    snap.unloaded.append("\(m.id)（端口 \(m.port)）")
                    continue
                }
                let up = connectable(m.port)
                let holder = procs.first { $0.ports.contains(m.port) }
                if let h = holder, up {
                    claimed.insert(h.pid)
                    let running = isRunning(h.pid)
                    append(pid: h.pid, name: m.id, mem: h.memBytes,
                           state: running ? .running : .idle,
                           note: running
                                ? "pid \(h.pid) · 端口 \(m.port) · 正在处理请求"
                                : "pid \(h.pid) · 端口 \(m.port) · 权重在内存、无计算")
                } else if up {
                    append(pid: nil, name: m.id, mem: 0, state: .idle,
                           note: "端口 \(m.port) 在监听，占用进程未识别")
                } else {
                    append(pid: nil, name: m.id, mem: 0, state: .failed,
                           note: "常驻但端口 \(m.port) 连不上")
                }
            }
        }

        // 4.4 网关没声明的模型服务进程（自建 llama-server / Ollama 之类）
        for p in procs where !claimed.contains(p.pid) {
            let running = isRunning(p.pid)
            let livePort = p.ports.first { connectable($0) }
            let state: ModelState
            let note: String
            if let port = livePort {
                state = running ? .running : .idle
                note = running ? "pid \(p.pid) · 端口 \(port) · 正在处理请求"
                               : "pid \(p.pid) · 端口 \(port) · 权重在内存、无计算"
            } else if p.ports.isEmpty {
                // 没有服务端口的（Draw Things 这类应用内模型）不是故障，只看有没有在算
                state = running ? .running : .idle
                note = "pid \(p.pid) · 应用内模型，无服务端口"
            } else {
                state = .failed
                note = "pid \(p.pid) · 端口 \(p.ports.map(String.init).joined(separator: "/")) 连不上"
            }
            append(pid: p.pid, name: p.display, mem: p.memBytes, state: state, note: note)
        }

        // 4.5 排序：内存占用降序（故障但无内存的排最后）
        snap.rows.sort { $0.memGB > $1.memGB }
        // 一个进程托管多个模型时无法把内存拆开 ⇒ 逐行标 *，不假装知道各占多少
        for i in snap.rows.indices {
            if let p = snap.rows[i].pid, (pidUse[p] ?? 0) > 1 { snap.rows[i].shared = true }
        }

        prevAt = now
        return snap
    }
}

// ============================================================
// MARK: - 进程榜窗口（点 Dock 图标 / 菜单打开）
// ============================================================

final class ProcessWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let sampler = ProcessSampler()
    private var timer: Timer?

    private var summaryLabel: NSTextField?
    private var breakdownLabel: NSTextField?
    private var swapLabel: NSTextField?
    private var nameLabels: [NSTextField] = []
    private var valueLabels: [NSTextField] = []
    private var toggleMenuBar: NSButton?
    // 本机 AI 模型一栏
    private let modelSampler = LocalModelSampler()
    private let modelRowLimit = 4
    private var modelNameLabels: [NSTextField] = []
    private var modelStateLabels: [NSTextField] = []
    private var modelMemLabels: [NSTextField] = []
    private var modelFootnote: NSTextField?
    private var cachedModels: ModelSnapshot?
    private var modelSampledAt = Date.distantPast

    /// 由 AppDelegate 注入：取当前总占用率
    var sampleProvider: (() -> Sample)?

    func show() {
        if window == nil { build() }
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTimer()
        refresh()
    }

    private func startTimer() {
        guard timer == nil else { return }
        // 首次调用 GPU 只建立基准（无差值），第二次起才有数
        _ = sampler.topGPU()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopTimer()   // 窗口关了就不再采样，空载零代价
    }

    @discardableResult
    private func section(_ title: String, top: CGFloat, into content: NSView) -> NSTextField {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: 24, y: top, width: 380, height: 16)
        content.addSubview(t)
        return t
    }

    // ---- 模型行数自适应 ----
    // 模型通常只有 1–2 个，固定 4 行会留出大片空白。这里按实际行数把窗口整体收短：
    // 顶部区跟着上移（保持离窗口顶部的距离），下方区坐标不动（保持彼此间距）。
    private var topViews: [(view: NSView, baseY: CGFloat)] = []
    private var belowViews: [(view: NSView, baseY: CGFloat)] = []
    private var appliedShrink: CGFloat = -1

    private func trackTop(_ v: NSView) { topViews.append((v, v.frame.origin.y)) }
    private func trackBelow(_ v: NSView) { belowViews.append((v, v.frame.origin.y)) }

    private func applyModelLayout(rowCount: Int) {
        let used = max(1, min(modelRowLimit, rowCount))
        let dy = CGFloat(modelRowLimit - used) * 24
        guard dy != appliedShrink, let w = window else { return }
        appliedShrink = dy
        for (v, y) in topViews { v.frame.origin.y = y - dy }
        // 下方区（脚注 / 三段榜 / 按钮）不随模型行数移动，显式复位一次，保证窗口缩短后不漂移
        for (v, y) in belowViews { v.frame.origin.y = y }
        for i in 0..<modelRowLimit {
            guard i < modelNameLabels.count else { continue }
            let hide = i >= used
            modelNameLabels[i].isHidden = hide
            modelStateLabels[i].isHidden = hide
            modelMemLabels[i].isHidden = hide
        }
        var f = w.frame
        f.origin.y += dy
        f.size.height -= dy
        w.setFrame(f, display: true)
    }

    // ---- 进程行 ----
    private func row(y: CGFloat, into content: NSView) {
        let name = NSTextField(labelWithString: "—")
        name.font = NSFont.systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 24, y: y, width: 310, height: 18)
        content.addSubview(name)

        let val = NSTextField(labelWithString: "")
        val.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        val.alignment = .right
        val.frame = NSRect(x: 340, y: y, width: 96, height: 18)
        content.addSubview(val)

        nameLabels.append(name)
        valueLabels.append(val)
        trackBelow(name)
        trackBelow(val)
    }

    /// 模型行：名称（左）· 状态（中，带颜色）· 内存占用（右）
    private func modelRow(y: CGFloat, into content: NSView) {
        let name = NSTextField(labelWithString: "—")
        name.font = NSFont.systemFont(ofSize: 12.5)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 24, y: y, width: 226, height: 17)
        content.addSubview(name)

        let st = NSTextField(labelWithString: "")
        st.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        st.lineBreakMode = .byTruncatingTail
        st.frame = NSRect(x: 258, y: y + 1, width: 88, height: 16)
        content.addSubview(st)

        let mem = NSTextField(labelWithString: "")
        mem.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        mem.alignment = .right
        mem.frame = NSRect(x: 356, y: y, width: 80, height: 17)
        content.addSubview(mem)

        modelNameLabels.append(name)
        modelStateLabels.append(st)
        modelMemLabels.append(mem)
        trackTop(name)
        trackTop(st)
        trackTop(mem)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "DockStats"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let content = NSView(frame: w.contentLayoutRect)
        w.contentView = content

        // 顶部总览
        let s = NSTextField(labelWithString: "当前总占用")
        s.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        s.textColor = .tertiaryLabelColor
        s.frame = NSRect(x: 24, y: 606, width: 200, height: 16)
        content.addSubview(s)
        trackTop(s)

        let sum = NSTextField(labelWithString: "—")
        sum.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        sum.frame = NSRect(x: 24, y: 582, width: 412, height: 20)
        content.addSubview(sum)
        summaryLabel = sum
        trackTop(sum)

        // 内存分解：让「进程榜加起来才几个 GB」有处可解释
        let bd = NSTextField(labelWithString: "")
        bd.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        bd.textColor = .secondaryLabelColor
        bd.lineBreakMode = .byTruncatingTail
        bd.frame = NSRect(x: 24, y: 554, width: 412, height: 16)
        content.addSubview(bd)
        breakdownLabel = bd
        trackTop(bd)

        // 换页（压缩内存见上一行；图标上不显示这两项，只在这里看）
        let sw = NSTextField(labelWithString: "")
        sw.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        sw.textColor = .secondaryLabelColor
        sw.lineBreakMode = .byTruncatingTail
        sw.frame = NSRect(x: 24, y: 538, width: 412, height: 16)
        content.addSubview(sw)
        swapLabel = sw
        trackTop(sw)

        // 本机 AI 模型（内存里挂着的本地模型 + 运行状态）
        trackTop(section("本机 AI 模型（按内存占用排序）", top: 506, into: content))
        for i in 0..<modelRowLimit { modelRow(y: 482 - CGFloat(i) * 24, into: content) }

        let foot = NSTextField(labelWithString: "")
        foot.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        foot.textColor = .secondaryLabelColor
        foot.lineBreakMode = .byTruncatingTail
        foot.frame = NSRect(x: 24, y: 388, width: 412, height: 16)
        content.addSubview(foot)
        modelFootnote = foot
        trackBelow(foot)

        // 三段排行
        trackBelow(section("CPU 占用最高", top: 360, into: content))
        for i in 0..<3 { row(y: 334 - CGFloat(i) * 25, into: content) }
        trackBelow(section("GPU 占用最高", top: 256, into: content))
        for i in 0..<3 { row(y: 230 - CGFloat(i) * 25, into: content) }
        trackBelow(section("内存占用最高（物理占用，含共享页）", top: 152, into: content))
        for i in 0..<3 { row(y: 126 - CGFloat(i) * 25, into: content) }

        // 底部按钮
        let quit = NSButton(title: "退出 DockStats", target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 326, y: 24, width: 110, height: 28)
        content.addSubview(quit)
        trackBelow(quit)

        let toggle = NSButton(title: "菜单栏读数", target: self, action: #selector(toggleMenuBarItem(_:)))
        toggle.bezelStyle = .rounded
        toggle.setButtonType(.pushOnPushOff)
        toggle.frame = NSRect(x: 24, y: 24, width: 110, height: 28)
        content.addSubview(toggle)
        toggleMenuBar = toggle
        trackBelow(toggle)

        self.window = w
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func toggleMenuBarItem(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.setMenuBarVisible(sender.state == .on)
    }

    func refresh() {
        guard window != nil else { return }

        if let s = sampleProvider?() {
            let gpu = s.gpu.map { String(format: "%.0f%%", $0) } ?? "—"
            summaryLabel?.stringValue = String(
                format: "CPU %.0f%% · GPU %@ · 内存 %.0f%%（%.1f/%.0f GB）",
                s.cpu, gpu, s.memPct, s.memUsedGB, s.memTotalGB)
            breakdownLabel?.stringValue = String(
                format: "内存分解：应用 %.1f + 联动 %.1f + 压缩 %.1f ｜ 缓存 %.1f ｜ 空闲 %.1f GB",
                s.memAppGB, s.memWiredGB, s.memCompressedGB, s.memCachedGB, s.memFreeGB)

            let sw = sampler.swapUsage()
            if sw.totalGB > 0.01 {
                swapLabel?.stringValue = String(
                    format: "Z 压缩+换页 %.0f%%　｜　已换页 %.1f / 上限 %.1f GB",
                    s.memPressurePct, sw.usedGB, sw.totalGB)
            } else {
                swapLabel?.stringValue = String(format: "Z 压缩+换页 %.0f%%　｜　未使用换页",
                                                s.memPressurePct)
            }
        }

        // 本机 AI 模型（内存里挂着的本地模型 + 运行状态）
        // 模型状态不需要 2 秒粒度：4 秒一采，省掉一半 ioreg / 全进程扫描开销。
        let models: ModelSnapshot
        if let c = cachedModels, Date().timeIntervalSince(modelSampledAt) < 4 {
            models = c
        } else {
            models = modelSampler.refresh()
            cachedModels = models
            modelSampledAt = Date()
        }
        applyModelLayout(rowCount: models.rows.count)
        for i in 0..<modelRowLimit {
            guard i < modelNameLabels.count else { continue }
            if i < models.rows.count {
                let r = models.rows[i]
                modelNameLabels[i].stringValue = r.name + (r.shared ? " *" : "")
                modelNameLabels[i].textColor = r.state == .failed ? .secondaryLabelColor : .labelColor
                modelStateLabels[i].stringValue = r.state.text
                modelStateLabels[i].textColor = r.state.color
                modelMemLabels[i].stringValue = r.memGB > 0.01 ? String(format: "%.2f GB", r.memGB) : "—"
                modelMemLabels[i].textColor = r.state == .failed ? .secondaryLabelColor : .labelColor
                let tip = r.note
                modelNameLabels[i].toolTip = tip
                modelStateLabels[i].toolTip = tip
                modelMemLabels[i].toolTip = tip
            } else {
                modelNameLabels[i].stringValue = i == 0 ? "未发现本地模型进程" : ""
                modelNameLabels[i].textColor = .tertiaryLabelColor
                modelStateLabels[i].stringValue = ""
                modelMemLabels[i].stringValue = ""
                modelNameLabels[i].toolTip = nil
                modelStateLabels[i].toolTip = nil
                modelMemLabels[i].toolTip = nil
            }
        }
        var footParts: [String] = []
        if !models.gatewayUp { footParts.append("本地网关 8010 无响应，只列已加载进程") }
        if !models.unloaded.isEmpty { footParts.append("未加载：" + models.unloaded.joined(separator: "、")) }
        if models.rows.count > modelRowLimit { footParts.append("另有 \(models.rows.count - modelRowLimit) 个未显示") }
        if models.rows.contains(where: { $0.shared }) { footParts.append("* 同一进程托管多个模型，内存是进程合计") }
        modelFootnote?.stringValue = footParts.joined(separator: "　")

        let cpu = sampler.topCPU()
        let gpu = sampler.topGPU()
        let mem = sampler.topMemory()

        for (section, stats) in [(0, cpu), (1, gpu), (2, mem)] {
            for i in 0..<3 {
                let idx = section * 3 + i
                guard idx < nameLabels.count else { continue }
                if i < stats.count {
                    let st = stats[i]
                    nameLabels[idx].stringValue = st.name
                    switch section {
                    case 0:  valueLabels[idx].stringValue = String(format: "%.1f%%", st.value)
                    case 1:  valueLabels[idx].stringValue = String(format: "%.1f%%", st.value)
                    default: valueLabels[idx].stringValue = String(format: "%.2f GB",
                                                                   st.value / 1_073_741_824)
                    }
                    valueLabels[idx].textColor = section == 2
                        ? .labelColor
                        : levelColor(min(100, st.value))
                } else {
                    nameLabels[idx].stringValue = "—"
                    valueLabels[idx].stringValue = ""
                }
            }
        }
    }
}

// ============================================================
// MARK: - AppDelegate
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cpuSampler = CPUSampler()
    private let memSampler = MemorySampler()
    private let gpuSampler = GPUSampler()
    private let status = StatusItemController()
    private var procWindow: ProcessWindowController!
    private var timer: Timer?
    private var animator: Timer?
    private var lastIcon: NSImage?
    private var showDockIcon = true
    private var target = Sample()
    private var display = Sample()
    private var lastDrawn = Sample(cpu: -1, gpu: -1, memPct: -1, memUsedGB: 0, memTotalGB: 0)

    func applicationDidFinishLaunching(_ note: Notification) {
        procWindow = ProcessWindowController()
        procWindow.sampleProvider = { [weak self] in self?.target ?? Sample() }

        // GPU 需要两次采样才算得出占用率，先建基准
        gpuSampler.prime()

        buildMenu()
        status.item.isVisible = false          // 菜单栏读数默认隐藏

        // 首次采样：内存立刻有值，CPU 与 GPU 需要两拍才有增量
        let m0 = memSampler.next()
        target.memPct = m0.pct; target.memUsedGB = m0.usedGB; target.memTotalGB = m0.totalGB
        let d0 = memSampler.last
        let sw0 = swapUsedGB()
        target.swapUsedGB = sw0
        target.memPressurePct = d0.totalGB > 0
            ? min(100, (d0.compressedGB + sw0) / d0.totalGB * 100) : 0
        display.memPct = m0.pct; display.memUsedGB = m0.usedGB; display.memTotalGB = m0.totalGB
        display.memPressurePct = target.memPressurePct
        _ = cpuSampler.next()

        // 采样 1 秒一次
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 插值重绘 0.5 秒一次（2 Hz，既平滑又省）
        let a = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.animate() }
        RunLoop.main.add(a, forMode: .common)
        animator = a
    }

    private func buildMenu() {
        let menu = NSMenu()

        let dockswitch = NSMenuItem(title: "在 Dock 显示读数", action: #selector(toggleDock(_:)), keyEquivalent: "")
        dockswitch.state = showDockIcon ? .on : .off
        dockswitch.target = self
        menu.addItem(dockswitch)

        let winswitch = NSMenuItem(title: "显示菜单栏读数", action: #selector(toggleMenuBarItem(_:)), keyEquivalent: "")
        winswitch.state = .off
        winswitch.target = self
        menu.addItem(winswitch)

        let openItem = NSMenuItem(title: "打开进程排行窗口", action: #selector(openProcWindow(_:)), keyEquivalent: "d")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DockStats", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        status.item.menu = menu
    }

    func tick() {
        // 1) 真实采样
        if let c = cpuSampler.next() { target.cpu = c }
        let mem = memSampler.next()
        target.memPct = mem.pct
        target.memUsedGB = mem.usedGB
        target.memTotalGB = mem.totalGB
        let d = memSampler.last
        target.memAppGB = d.appGB
        target.memWiredGB = d.wiredGB
        target.memCompressedGB = d.compressedGB
        target.memCachedGB = d.cachedGB
        target.memFreeGB = d.freeGB
        // 内存压力水位 = (被压缩 + 被换出) ÷ 物理内存总量
        // 含义：系统为了腾地方，把多大比例的物理内存压起来或挪到磁盘了
        let swapGB = swapUsedGB()
        target.swapUsedGB = swapGB
        target.memPressurePct = d.totalGB > 0
            ? min(100, (d.compressedGB + swapGB) / d.totalGB * 100) : 0
        if let g = gpuSampler.next() { target.gpu = g }
    }

    /// 2) 每 0.25 秒把显示值向真实值插值 → Dock 图标平滑滑动，而不是一秒一跳
    func animate() {
        let k = 0.35
        var s = Sample()
        s.cpu = display.cpu + (target.cpu - display.cpu) * k
        s.memPct = display.memPct + (target.memPct - display.memPct) * k
        s.memPressurePct = display.memPressurePct
            + (target.memPressurePct - display.memPressurePct) * k
        s.memUsedGB = target.memUsedGB
        s.memTotalGB = target.memTotalGB
        s.memAppGB = target.memAppGB
        s.memWiredGB = target.memWiredGB
        s.memCompressedGB = target.memCompressedGB
        s.memCachedGB = target.memCachedGB
        s.memFreeGB = target.memFreeGB
        s.swapUsedGB = target.swapUsedGB
        if abs(s.memPressurePct - target.memPressurePct) < 0.2 {
            s.memPressurePct = target.memPressurePct
        }
        if let tg = target.gpu {
            let cur = display.gpu ?? tg
            s.gpu = cur + (tg - cur) * k
            if abs((s.gpu ?? 0) - tg) < 0.4 { s.gpu = tg }
        } else {
            s.gpu = nil
        }
        if abs(s.cpu - target.cpu) < 0.2 { s.cpu = target.cpu }
        if abs(s.memPct - target.memPct) < 0.2 { s.memPct = target.memPct }
        display = s

        if status.item.isVisible { status.update(s) }
        if showDockIcon {
            // 图标上显示的是整数百分比 ⇒ 只有整数位变了才值得重绘。
            // 小数位的抖动肉眼看不出，却会让 Dock 每 0.5 秒重合成一次、白烧 CPU。
            let gpuChanged: Bool
            switch (s.gpu, lastDrawn.gpu) {
            case (nil, nil):            gpuChanged = false
            case let (a?, b?):          gpuChanged = round(a) != round(b)
            default:                    gpuChanged = true
            }
            let moved = round(s.cpu) != round(lastDrawn.cpu)
                || round(s.memPct) != round(lastDrawn.memPct)
                || round(s.memPressurePct) != round(lastDrawn.memPressurePct)
                || gpuChanged
                || lastDrawn.cpu < 0
            if moved {
                let icon = makeDockIcon(s)
                lastIcon = icon
                NSApplication.shared.applicationIconImage = icon
                lastDrawn = s
            }
        }
    }

    @objc private func toggleDock(_ sender: NSMenuItem) {
        showDockIcon.toggle()
        sender.state = showDockIcon ? .on : .off
        if showDockIcon { tick() }
    }

    @objc private func openProcWindow(_ sender: Any?) {
        procWindow.show()
    }

    @objc private func toggleMenuBarItem(_ sender: NSMenuItem) {
        let on = !status.item.isVisible
        setMenuBarVisible(on)
        sender.state = on ? .on : .off
    }

    /// 菜单栏读数开关（窗口里的按钮也走这里）
    func setMenuBarVisible(_ visible: Bool) {
        status.item.isVisible = visible
        if visible { status.update(display) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // 点 Dock 图标（有/无窗口）都弹出进程排行窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        procWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关窗口不退出，继续常驻 Dock
    }
}

// ============================================================
// MARK: - 入口
// ============================================================

// ---- 自检模式：--dump 采样一次并把 Dock 图标写成 PNG（用于无屏幕录制权限时的实测验证）----
// ---- 自检模式：--procs 打印三榜（窗口内容的数据源），用于无 GUI 时验证采样 ----
if CommandLine.arguments.contains("--procs") {
    let sampler = ProcessSampler()
    _ = sampler.topGPU()                            // 建立 GPU 基准
    Thread.sleep(forTimeInterval: 1.5)
    let cpu = sampler.topCPU()
    let gpu = sampler.topGPU()
    let mem = sampler.topMemory()
    print("=== CPU 占用最高 ===")
    for s in cpu { print(String(format: "  %-32s %6.1f%%  (pid %d)", (s.name as NSString).utf8String!, s.value, s.pid)) }
    print("=== GPU 占用最高（% of one GPU）===")
    if gpu.isEmpty { print("  (首拍无基准)") }
    for s in gpu { print(String(format: "  %-32s %6.1f%%  (pid %d)", (s.name as NSString).utf8String!, s.value, s.pid)) }
    print("=== 内存占用最高（物理占用 phys_footprint，含共享页）===")
    for s in mem { print(String(format: "  %-32s %6.2f GB  (pid %d)", (s.name as NSString).utf8String!, s.value / 1_073_741_824, s.pid)) }
    let sw = sampler.swapUsage()
    print(String(format: "=== 换页 swap：%.1f / %.1f GB ===", sw.usedGB, sw.totalGB))
    exit(0)
}

// ---- 自检模式：--models 打印「本机 AI 模型」一栏的数据源（无 GUI 时验证用）----
if CommandLine.arguments.contains("--models") {
    let ms = LocalModelSampler()
    if let g = CommandLine.arguments.first(where: { $0.hasPrefix("--gateway=") }),
       let p = Int(g.replacingOccurrences(of: "--gateway=", with: "")) {
        ms.gatewayPort = p
    }
    _ = ms.refresh()                        // 首拍只建基准
    Thread.sleep(forTimeInterval: 2.0)      // 跨过一个活动窗口
    let snap = ms.refresh()
    print("网关 \(ms.gatewayPort)：\(snap.gatewayUp ? "在线" : "无响应")")
    print("=== 本机 AI 模型（按内存占用排序）===")
    if snap.rows.isEmpty { print("  （未发现本地模型进程）") }
    for r in snap.rows {
        let star = r.shared ? " *" : ""
        let mem = r.memGB > 0.01 ? String(format: "%.2f GB", r.memGB) : "—"
        print("  \(r.name)\(star)　\(r.state.text)　\(mem)　｜　\(r.note)")
    }
    if !snap.unloaded.isEmpty {
        print("=== 未加载 ===")
        for u in snap.unloaded { print("  \(u)") }
    }
    if !snap.gatewayUp { print("（网关 \(ms.gatewayPort) 无响应：只列已加载的进程，无法判断哪个模型该常驻）") }
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    _ = NSApplication.shared   // 初始化 AppKit（字体/颜色/绘图上下文）
    let outDir = CommandLine.arguments
        .first { $0.hasPrefix("--out=") }?
        .replacingOccurrences(of: "--out=", with: "") ?? NSTemporaryDirectory()

    let cpuS = CPUSampler()
    let memS = MemorySampler()
    let gpuS = GPUSampler()

    _ = cpuS.next()                      // CPU 建基准
    gpuS.prime()                         // GPU 建基准
    Thread.sleep(forTimeInterval: 2.2)   // 必须跨过 GPU 的 2s 采样间隔
    let cpu = cpuS.next() ?? 0
    let mem = memS.next()
    let gpuB = gpuS.next()

    var s = Sample()
    s.cpu = cpu
    s.gpu = gpuB
    s.memPct = mem.pct
    s.memUsedGB = mem.usedGB
    s.memTotalGB = mem.totalGB
    let d = memS.last
    s.memAppGB = d.appGB; s.memWiredGB = d.wiredGB; s.memCompressedGB = d.compressedGB
    s.memCachedGB = d.cachedGB; s.memFreeGB = d.freeGB
    s.swapUsedGB = swapUsedGB()
    s.memPressurePct = d.totalGB > 0 ? min(100, (d.compressedGB + s.swapUsedGB) / d.totalGB * 100) : 0

    // --mock=CPU,GPU,MEM：强制指定显示数值，用于验收边界态（如 100/100/100）
    if let mock = CommandLine.arguments.first(where: { $0.hasPrefix("--mock=") }) {
        let parts = mock.replacingOccurrences(of: "--mock=", with: "")
            .split(separator: ",").compactMap { Double($0) }
        if parts.count >= 3 {
            s.cpu = parts[0]; s.gpu = parts[1]; s.memPct = parts[2]
        }
        if parts.count >= 4 { s.memPressurePct = parts[3] }
    }

    print(String(format: "cpu=%.1f gpu=%@ mem=%.1f%% (%.1f/%.0f GB) chip=%@",
                 s.cpu,
                 s.gpu.map { String(format: "%.1f", $0) } ?? "nil",
                 s.memPct, s.memUsedGB, s.memTotalGB, gpuName()))
    if CommandLine.arguments.contains("--verbose") {
        print(String(format: "  mem: 应用 %.1f + 联动 %.1f + 压缩 %.1f = %.1f GB ｜ 文件缓存 %.1f GB（可回收）｜ 空闲 %.1f GB",
                     s.memAppGB, s.memWiredGB, s.memCompressedGB, s.memUsedGB,
                     s.memCachedGB, s.memFreeGB))
        print(String(format: "  Z(压缩+换页水位): (%.1f 压缩 + %.1f 换页) / %.0f = %.1f%%",
                     s.memCompressedGB, s.swapUsedGB, s.memTotalGB, s.memPressurePct))
    }

    let icon = makeDockIcon(s)
    if let tiff = icon.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("dockicon.png")
        try? png.write(to: url)
        print("icon=\(url.path)")
    }
    exit(0)
}

// 单实例：LaunchAgent 常驻的实例 + 用户 `open`/双击起的实例会各自画一份 Dock 图标，
// 两份互相抢图标、窗口也会各开一个。后启动的那份把先启动的激活到前台，自己退出
// （plist 的 KeepAlive 只对非零退出生效，所以正常 exit(0) 不会被 launchd 拉起）。
// 自检模式（--dump/--models/--procs）带参数，不参与这个判断。
if CommandLine.arguments.count <= 1 {
    let me = ProcessInfo.processInfo.processIdentifier
    let bundleID = Bundle.main.bundleIdentifier ?? "com.tanfang.dockstats"
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    if let first = others.min(by: { $0.processIdentifier < $1.processIdentifier }),
       first.processIdentifier < me {
        first.activate(options: [.activateIgnoringOtherApps])
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .regular：Dock 里出现可点击的应用图标（而非仅菜单栏的 accessory）
app.setActivationPolicy(.regular)
app.run()
