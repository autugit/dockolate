// Dockolate — 在 Dock 图标与菜单栏实时显示 CPU / GPU / 内存占用率
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
    private var dockCheckbox: NSButton?
    private var menuCheckbox: NSButton?
    // 本机 AI 引擎一栏
    private let modelSampler = EngineWatcher()
    private let engineQueue = DispatchQueue(label: "io.github.autugit.dockolate.engines", qos: .utility)
    private var engineProbeBusy = false
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

    // ---- 开发自检：把主窗口离屏渲染成 PNG ----
    // 本机没有屏幕录制权限（screencapture 直接报 "could not create image from display"），
    // 所以界面的验收面改成进程内 cacheDisplay —— 不碰 TCC，拿到的是真实像素。
    // 用法：Dockolate --shot-panel=/tmp/panel.png [--demo-models]
    /// 自检用：直接注入一份模型快照，覆盖「加载中 / 出现故障」这类现场难碰到的状态
    func selfCheckInjectModels(_ snap: ModelSnapshot) {
        cachedModels = snap
        modelSampledAt = Date()
    }

    func selfCheckRenderPNG(to path: String) -> Bool {
        guard let w = window, let v = w.contentView else { return false }
        refresh()
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        // cacheDisplay 只画内容视图、不画窗口背景，而且必须在**位图的绘图上下文**里先铺底色 ——
        // 直接调 NSBezierPath.fill() 落在空上下文里，什么都不会发生（踩过）。
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: v.bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
            v.cacheDisplay(in: v.bounds, to: rep)
        } else {
            NSGraphicsContext.restoreGraphicsState()
            v.cacheDisplay(in: v.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
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
    /// 建窗时的 frame（含标题栏）—— 每次都用它算目标高度，绝不在当前高度上做增量
    /// （踩过：行数在 1↔2 之间来回变时，每次 `height -= dy` 会把窗口越削越扁，顶部内容被裁掉）
    private var baseFrame: NSRect?

    private func trackTop(_ v: NSView) { topViews.append((v, v.frame.origin.y)) }
    private func trackBelow(_ v: NSView) { belowViews.append((v, v.frame.origin.y)) }

    private func applyModelLayout(rowCount: Int) {
        let used = max(1, min(modelRowLimit, rowCount))
        let dy = CGFloat(modelRowLimit - used) * 24
        guard dy != appliedShrink, let w = window, let bf = baseFrame else { return }
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
        // 目标高度 = 基准高度 − 省下的行高；顶边位置保持不动
        let targetHeight = bf.height - dy
        var f = w.frame
        let topEdge = f.origin.y + f.height
        f.size.height = targetHeight
        f.origin.y = topEdge - targetHeight
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
        w.title = "Dockolate"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)   // 固定浅色：截图验收与系统深色模式解耦
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
        let quit = NSButton(title: "退出 Dockolate", target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 326, y: 24, width: 110, height: 28)
        content.addSubview(quit)
        trackBelow(quit)

        // 两个显示面各自开关（默认 Dock 开、菜单栏关），选择会被记住
        let dockBox = NSButton(checkboxWithTitle: "Dock 图标读数", target: self,
                               action: #selector(toggleDockCheckbox(_:)))
        dockBox.frame = NSRect(x: 24, y: 26, width: 130, height: 20)
        content.addSubview(dockBox)
        dockCheckbox = dockBox
        trackBelow(dockBox)

        let menuBox = NSButton(checkboxWithTitle: "菜单栏读数", target: self,
                               action: #selector(toggleMenuBarCheckbox(_:)))
        menuBox.frame = NSRect(x: 160, y: 26, width: 120, height: 20)
        content.addSubview(menuBox)
        menuCheckbox = menuBox
        trackBelow(menuBox)
        syncToggleStates()

        self.window = w
        baseFrame = w.frame
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func toggleMenuBarCheckbox(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.setMenuBarVisible(sender.state == .on)
        syncToggleStates()
    }

    @objc private func toggleDockCheckbox(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.setDockVisible(sender.state == .on)
        syncToggleStates()
    }

    /// 勾选状态跟着实际状态走（菜单栏菜单里改过也要同步回窗口）
    private func syncToggleStates() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        dockCheckbox?.state = d.dockIconVisible ? .on : .off
        menuCheckbox?.state = d.menuBarVisible ? .on : .off
    }

    /// 4 秒一次把引擎探测丢到后台；探测期间 UI 继续显示上一次的结果
    private func triggerEngineProbeIfNeeded() {
        guard !engineProbeBusy else { return }
        guard cachedModels == nil || Date().timeIntervalSince(modelSampledAt) >= 4 else { return }
        engineProbeBusy = true
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            let snap = self.modelSampler.refresh()
            DispatchQueue.main.async {
                self.cachedModels = snap
                self.modelSampledAt = Date()
                self.engineProbeBusy = false
                self.refresh()          // 用新缓存重画（refresh 只在主线程跑）
            }
        }
    }

    func refresh() {
        guard window != nil else { return }
        syncToggleStates()

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

        // 本机 AI 引擎一栏：探测丢后台（15 个端口 × 各家 API 试探可能耗时），
        // 主线程只渲染缓存结果 —— 绝不卡窗口。
        triggerEngineProbeIfNeeded()
        let models = cachedModels ?? ModelSnapshot()
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
        if models.enginesFound == 0 && models.rows.isEmpty {
            footParts.append("没探测到本地引擎")
        }
        if models.rows.count > modelRowLimit {
            let hidden = models.rows.suffix(models.rows.count - modelRowLimit)
            let hiddenUncertain = hidden.filter { $0.state == .uncertain }.count
            footParts.append("另有 \(hidden.count) 个未显示"
                             + (hiddenUncertain > 0 ? "（含 \(hiddenUncertain) 个待确认）" : ""))
        }
        if models.rows.contains(where: { $0.shared }) { footParts.append("* 同一进程托管多个模型（单个模型的内存见行内提示）") }
        // 未加载清单：按脚注实际可用宽度装配，塞不下就收成「等 N 个」。
        // 之前整串直接拼上，模型名一长就被省略号吃掉（尾部的模型看着像没被识别到）。完整清单进悬停提示。
        if !models.unloaded.isEmpty {
            let font = NSFont.systemFont(ofSize: 10.5)
            func textWidth(_ s: String) -> CGFloat {
                (s as NSString).size(withAttributes: [.font: font]).width
            }
            let othersWidth = footParts.isEmpty ? 0 : textWidth(footParts.joined(separator: "　")) + 21
            let budget = max(140, 412 - othersWidth)   // 412 = 脚注框宽
            let names = models.unloaded
            var text = "未加载："
            var shown = 0
            for (i, n) in names.enumerated() {
                let candidate = i == 0 ? n : "、" + n
                let suffix = names.count - (i + 1) > 0 ? " 等 \(names.count) 个" : ""
                guard textWidth(text + candidate + suffix) <= budget else { break }
                text += candidate
                shown += 1
            }
            let unloadedNote: String
            if shown == 0 {
                unloadedNote = "未加载 \(names.count) 个（悬停看全部）"
            } else if shown < names.count {
                unloadedNote = text + " 等 \(names.count) 个"
            } else {
                unloadedNote = text
            }
            footParts.insert(unloadedNote, at: 0)
        }
        modelFootnote?.stringValue = footParts.joined(separator: "　")
        modelFootnote?.toolTip = models.unloaded.isEmpty ? nil : models.unloaded.joined(separator: "、")

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
    private var invWindow: InventoryWindowController!
    private var timer: Timer?
    private var animator: Timer?
    private var lastIcon: NSImage?
    private var showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    private var showMenuBar = UserDefaults.standard.bool(forKey: "showMenuBar")
    private var target = Sample()
    private var display = Sample()
    private var lastDrawn = Sample(cpu: -1, gpu: -1, memPct: -1, memUsedGB: 0, memTotalGB: 0)

    func applicationDidFinishLaunching(_ note: Notification) {
        procWindow = ProcessWindowController()
        procWindow.sampleProvider = { [weak self] in self?.target ?? Sample() }
        invWindow = InventoryWindowController()

        // GPU 需要两次采样才算得出占用率，先建基准
        gpuSampler.prime()

        buildMenu()
        status.item.isVisible = showMenuBar     // 菜单栏读数：默认关，选择会记住

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

        let dockswitch = NSMenuItem(title: "在 Dock 图标显示读数", action: #selector(toggleDock(_:)), keyEquivalent: "")
        dockswitch.state = showDockIcon ? .on : .off
        dockswitch.target = self
        dockswitch.tag = 101
        menu.addItem(dockswitch)

        let winswitch = NSMenuItem(title: "在菜单栏显示读数", action: #selector(toggleMenuBarItem(_:)), keyEquivalent: "")
        winswitch.state = showMenuBar ? .on : .off
        winswitch.target = self
        winswitch.tag = 102
        menu.addItem(winswitch)

        let openItem = NSMenuItem(title: "打开进程排行窗口", action: #selector(openProcWindow(_:)), keyEquivalent: "d")
        openItem.target = self
        menu.addItem(openItem)

        let invItem = NSMenuItem(title: "打开本机模型清单", action: #selector(openInventoryWindow(_:)), keyEquivalent: "i")
        invItem.target = self
        menu.addItem(invItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 Dockolate", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 Dockolate", action: #selector(quit), keyEquivalent: "q")
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
        setDockVisible(!showDockIcon)
        sender.state = showDockIcon ? .on : .off
    }

    @objc private func openInventoryWindow(_ sender: Any?) {
        invWindow.show()
    }

    @objc private func openProcWindow(_ sender: Any?) {
        procWindow.show()
    }

    /// 关于：署名与版本（自检模式不弹）
    @objc private func showAbout(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let alert = NSAlert()
        alert.messageText = "Dockolate \(version)"
        alert.informativeText = """
        Dock 里的一板巧克力 —— CPU / GPU / 内存水位，外加本机 AI 模型清单。

        作者：Autumemory · Hermes · DeepSeek v4.1 flash
        许可：MIT
        https://github.com/autugit/dockolate
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleMenuBarItem(_ sender: NSMenuItem) {
        setMenuBarVisible(!showMenuBar)
        sender.state = showMenuBar ? .on : .off
    }

    // ---- 两个显示面都可以单独开关，选择记进 UserDefaults（下次启动沿用）----
    var dockIconVisible: Bool { showDockIcon }
    var menuBarVisible: Bool { showMenuBar }

    /// Dock 图标读数开关。关掉后图标恢复系统默认外观
    func setDockVisible(_ visible: Bool) {
        showDockIcon = visible
        UserDefaults.standard.set(visible, forKey: "showDockIcon")
        if visible {
            tick()
            lastDrawn = Sample(cpu: -1, gpu: -1, memPct: -1, memUsedGB: 0, memTotalGB: 0)
        } else {
            NSApplication.shared.applicationIconImage = nil
        }
    }

    /// 菜单栏读数开关（窗口里的勾选框与状态栏菜单都走这里）
    func setMenuBarVisible(_ visible: Bool) {
        showMenuBar = visible
        UserDefaults.standard.set(visible, forKey: "showMenuBar")
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

// ---- 自检模式：--engines 打印「本机 AI 引擎」一栏的数据源（无 GUI 时验证用）----
// --ports=9000,9001 追加探测端口；--models 是旧名，保留兼容
if CommandLine.arguments.contains("--engines") || CommandLine.arguments.contains("--models") {
    let ms = EngineWatcher()
    if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--ports=") }) {
        ms.extraPorts = a.replacingOccurrences(of: "--ports=", with: "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    if CommandLine.arguments.contains("--ports-only") { ms.portsOnly = true }
    _ = ms.refresh()                        // 首拍只建基准
    Thread.sleep(forTimeInterval: 2.0)      // 跨过一个活动窗口
    let snap = ms.refresh()
    print("探测端口：\(snap.scannedPorts.map(String.init).joined(separator: " "))")
    print("活着的引擎：\(snap.enginesFound) 个")
    print("=== 本机 AI 模型（按内存占用排序）===")
    if snap.rows.isEmpty { print("  （没探测到本地模型）") }
    for r in snap.rows {
        let star = r.shared ? " *" : ""
        let mem = r.memGB > 0.01 ? String(format: "%.2f GB", r.memGB) : "—"
        print("  \(r.name)\(star)　\(r.state.text)　\(mem)　｜　\(r.note)")
    }
    if !snap.unloaded.isEmpty {
        print("=== 已下载未加载 ===")
        for u in snap.unloaded { print("  \(u)") }
    }
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

// 载荷「形状」摘要：只有键名 / 类型 / 条数，**不含任何取值**。
// 发现报告与 --probe 共用；这段输出是可以直接贴进 issue 的。
func payloadShape(_ v: Any, depth: Int = 0) -> String {
    if depth > 4 { return "…" }
    if let d = v as? [String: Any] {
        let keys = d.keys.sorted().prefix(12).map { "\($0):\(payloadShape(d[$0]!, depth: depth + 1))" }
        return "{" + keys.joined(separator: ", ") + (d.count > 12 ? ", …\(d.count - 12) 键" : "") + "}"
    }
    if let arr = v as? [Any] {
        return "[" + "\(arr.count) 条" + (arr.isEmpty ? "" : " × " + payloadShape(arr[0], depth: depth + 1)) + "]"
    }
    if v is String { return "String" }
    if v is NSNumber { return "Number" }
    if v is NSNull { return "null" }
    return "\(type(of: v))"
}

// ---- 自检模式：--check-adapters 打印生效中的签名表（来源 / 条目数 / 解析警告）----
// 新引擎要「不改代码就认」，就是往 adapters.json 里加数据；这条命令用来确认加对了。
if CommandLine.arguments.contains("--check-adapters") {
    let t = AdapterTable.shared
    print("=== 签名表来源（后者覆盖前者）===")
    for s in t.sources {
        print(String(format: "  %@  %@  %d 条目",
                     s.ok ? "✓" : "✗", s.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                     s.entries))
    }
    print("=== 生效条目 ===")
    print("  processHints: \(t.processHints.count) 条（外部条目优先于内置 68 条特征词）")
    print("  ports:        \(t.ports.count) 条（仅兜底；进程认不出来时才用）")
    print("  states:       \(t.states.count) 条")
    print("  roles:        \(t.roles.count) 条")
    print("  probePaths:   \(t.probePaths.count) 条 \(t.probePaths.isEmpty ? "" : t.probePaths.joined(separator: " "))")
    if !t.warnings.isEmpty {
        print("=== 警告（不影响运行，但这些条目被忽略了）===")
        for w in t.warnings { print("  ⚠ " + w) }
    }
    let ok = t.sources.allSatisfy { $0.ok }
    exit(ok ? 0 : 1)
}

// ---- 自检模式：--probe=<port> 打印一个端口的探测细节（给用户反馈用，不含取值）----
// 只输出**形状摘要**（键名 / 类型 / 条数），不输出模型名、路径、任何 key。
if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--probe=") }) {
    let port = Int(a.replacingOccurrences(of: "--probe=", with: "")) ?? 0
    guard port > 0 else { print("用法：--probe=<端口>"); exit(2) }
    let w = EngineWatcher()

    let paths = ["/v1/models", "/api/ps", "/api/tags", "/api/v0/models",
                 "/sdapi/v1/options", "/queue", "/props", "/health"] + AdapterTable.shared.probePaths
    print("=== 端口 \(port) 各接口 ===")
    for path in paths {
        if let obj = LocalHTTP.json(port: port, path: path) {
            print("  \(path)  有 JSON  \(payloadShape(obj))")
        } else {
            print("  \(path)  无应答 / 不是 JSON")
        }
    }
    let cands = w.collectCandidates(port: port, auth: [:])
    print("=== 候选（按信息量评分）===")
    if cands.isEmpty { print("  （一个形状都没认出来）") }
    for c in cands.sorted(by: { $0.score > $1.score }) {
        print("  \(c.adapter)  分=\(c.score)  常驻=\(c.loaded.count)  加载中=\(c.loading.count)  "
              + "故障=\(c.failed.count)  未加载=\(c.unloaded.count)  未映射状态=\(c.reported.count)")
    }
    if let hit = w.detectEngine(port: port, hint: "探测") {
        print("=== 选中 ===")
        print("  适配器=\(hit.adapter)  分=\(hit.score)  待确认=\(hit.uncertain)  \(hit.evidenceNote)")
    } else {
        print("=== 选中：无（会在界面占一行「待确认」）===")
    }
    exit(0)
}

// ---- 自检模式：--identify=<路径> 打印权重身份识别结果（目录或单文件）----
if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--identify=") }) {
    let p = (a.replacingOccurrences(of: "--identify=", with: "") as NSString).expandingTildeInPath
    guard let id = ModelIdentifier.identify(path: p) else {
        print("无法识别：\(p)")
        exit(1)
    }
    print("family=\(id.family ?? "—")")
    print("architecture=\(id.architecture ?? "—")")
    print("quant=\(id.quant ?? "—")")
    print("format=\(id.format ?? "—")")
    print("role=\(id.role.rawValue)")
    print(String(format: "bytes=%.2f GB  files=%d", Double(id.bytes) / 1_073_741_824, id.files))
    print("display=\(id.displayName)")
    exit(0)
}

// ---- 自检模式：--inventory 打印磁盘清单（运行时 + 在盘未登记）+ 对所有账 ----
// --dirs=a:b     追加扫描目录（冒号分隔）
// --no-defaults  只扫 --dirs 给的目录（回归测试用，避免本机权重污染断言）
// --json         机器可读输出
if CommandLine.arguments.contains("--inventory") {
    var cfg = ModelInventory.loadConfig()
    if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--dirs=") }) {
        cfg.extraDirs = a.replacingOccurrences(of: "--dirs=", with: "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }
    if CommandLine.arguments.contains("--no-defaults") {
        cfg.includeDefaults = false
        cfg.includeEngineDirs = false
    }
    let w = EngineWatcher()
    // 与 --engines 同一套参数：回归测试要能把本机真在跑的引擎排除在外
    if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--ports=") }) {
        w.extraPorts = a.replacingOccurrences(of: "--ports=", with: "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    if CommandLine.arguments.contains("--ports-only") { w.portsOnly = true }
    _ = w.refresh()
    Thread.sleep(forTimeInterval: 2.0)
    let runtime = w.refresh()
    let inv = ModelInventory().build(runtime: runtime, config: cfg)

    if CommandLine.arguments.contains("--json") {
        let rows: [[String: Any]] = inv.rows.map { r in
            var o: [String: Any] = [
                "title": r.title, "detail": r.detail, "state": r.state.text,
                "disk_gb": (r.diskGB * 100).rounded() / 100,
                "mem_gb": (r.memGB * 100).rounded() / 100,
                "note": r.note,
            ]
            o["unregistered"] = (r.state == .unloaded || r.state == .unregistered)
            return o
        }
        let obj: [String: Any] = [
            "rows": rows,
            "scanned_roots": inv.scannedRoots.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") },
            "running": inv.runningCount, "loaded_idle": inv.idleCount,
            "unregistered": inv.unregisteredCount, "uncertain": inv.uncertainCount,
            "total_disk_gb": (inv.totalDiskGB * 10).rounded() / 10,
            "truncated": inv.truncated,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let t = String(data: d, encoding: .utf8) { print(t) }
        exit(0)
    }

    print("=== 扫描根 ===")
    for r in inv.scannedRoots { print("  " + r.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
    print("=== 清单（\(inv.rows.count) 行：在跑 \(inv.runningCount) · 已装载 \(inv.idleCount) · "
          + "在盘未登记 \(inv.unregisteredCount) · 待确认 \(inv.uncertainCount)）===")
    for r in inv.rows {
        let disk = r.diskGB > 0.01 ? String(format: "%.2f GB", r.diskGB) : "—"
        let mem = r.memGB > 0.01 ? String(format: "%.2f GB", r.memGB) : "—"
        print("  \(r.title)　\(r.state.text)　盘 \(disk)　内存 \(mem)　｜　\(r.detail)")
    }
    if inv.truncated { print("  （清单超过上限，只显示前 400 行）") }
    exit(0)
}

// ---- 自检模式：--discovery-report=<path> 导出脱敏发现报告（贴 issue 用）----
// 只含：各端口的载荷「形状」、候选评分、选中的适配器、进程识别到的引擎名与计数。
// **不含**：模型名、绝对路径、pid、key、任何取值。
if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--discovery-report=") }) {
    let out = (a.replacingOccurrences(of: "--discovery-report=", with: "") as NSString).expandingTildeInPath
    let w = EngineWatcher()
    _ = w.refresh()
    Thread.sleep(forTimeInterval: 2.0)
    let snap = w.refresh()

    let paths = ["/v1/models", "/api/ps", "/api/tags", "/api/v0/models",
                 "/sdapi/v1/options", "/queue", "/props", "/health"] + AdapterTable.shared.probePaths
    var ports: [[String: Any]] = []
    for p in snap.scannedPorts {
        guard LocalHTTP.connectable(port: p) else { continue }
        var routes: [String: String] = [:]
        for path in paths {
            if let obj = LocalHTTP.json(port: p, path: path, timeoutMs: 400) {
                routes[path] = payloadShape(obj)
            }
        }
        guard !routes.isEmpty else { continue }
        let cands = w.collectCandidates(port: p, auth: [:])
        let hit = w.detectEngine(port: p, hint: "探测")
        ports.append([
            "port_kind": "declared_or_known",     // 不写真实端口号
            "shapes": routes,
            "candidates": cands.map { c in
                ["adapter": c.adapter, "score": c.score, "resident": c.loaded.count,
                 "loading": c.loading.count, "failed": c.failed.count,
                 "unloaded": c.unloaded.count, "unmapped_state": c.reported.count]
            },
            "chosen": hit.map { ["adapter": $0.adapter, "score": $0.score, "uncertain": $0.uncertain] } ?? [:] as [String: Any],
        ])
    }
    let report: [String: Any] = [
        "app": "Dockolate",
        "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
        "engines_found": snap.enginesFound,
        "model_rows": snap.rows.map { ["state": $0.state.text, "has_name": !$0.name.isEmpty] },
        "ports": ports,
        "notes": "shapes 只含键名/类型/条数；不含模型名、路径、pid、key",
    ]
    let data = (try? JSONSerialization.data(withJSONObject: report,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    try? data.write(to: URL(fileURLWithPath: out))
    print("report=\(out)（\(data.count) 字节，脱敏：无模型名 / 无路径 / 无 pid / 无 key）")
    exit(0)
}

// ---- 自检模式：--shot-inventory=<path> 把「本机模型清单」窗口离屏渲染成 PNG ----
// --demo-inventory 注入一份覆盖四种状态（在跑 / 已装载 / 在盘未登记 / 待确认）的快照
if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--shot-inventory=") }) {
    _ = NSApplication.shared
    let out = a.replacingOccurrences(of: "--shot-inventory=", with: "")
    let ctl = InventoryWindowController()
    ctl.show()
    RunLoop.main.run(until: Date().addingTimeInterval(6.0))   // 等后台扫描回来
    if CommandLine.arguments.contains("--demo-inventory") {
        var demo = InventorySnapshot()
        demo.scannedRoots = ["~/.cache/huggingface/hub", "~/mlx-models", "引擎声明的目录"]
        demo.rows = [
            InventoryRow(title: "Some-Video-Model-8bit", detail: "引擎声明的目录 · … · 正在处理请求",
                         state: .running, diskGB: 70.1, memGB: 28.06),
            InventoryRow(title: "Some-Chat-Model · 4bit gs64", detail: "~/mlx-models/some-chat-4bit",
                         state: .idle, diskGB: 16.5, memGB: 15.2),
            InventoryRow(title: "Some-Draft-Head · Q8_0 · 草稿头", detail: "HF 缓存 · models--org--name",
                         state: .unregistered, diskGB: 3.85, memGB: 0),
            InventoryRow(title: "Unknown-State-Model", detail: "引擎 A · 引擎自报状态「warmup-x」",
                         state: .uncertain, diskGB: 0, memGB: 0),
            InventoryRow(title: "Some-Image-Model · 8bit · VAE", detail: "自定义目录 · ~/models/img/vae",
                         state: .unregistered, diskGB: 1.26, memGB: 0),
        ]
        demo.runningCount = 1; demo.idleCount = 1
        demo.unregisteredCount = 2; demo.uncertainCount = 1
        demo.totalDiskGB = 91.7
        ctl.selfCheckInject(demo)
    }
    let ok = ctl.selfCheckRenderPNG(to: out)
    print(ok ? "inventory=\(out)" : "inventory=失败")
    exit(ok ? 0 : 1)
}

// ---- 自检模式：--shot-panel=<path> 把主窗口离屏渲染成 PNG ----
// 没有屏幕录制权限时（screencapture 报 could not create image from display），
// 这是唯一能「看到」界面的验收面：进程内 cacheDisplay，像素来自真实视图树。
if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--shot-panel=") }) {
    _ = NSApplication.shared
    let out = a.replacingOccurrences(of: "--shot-panel=", with: "")
    let cpuS = CPUSampler()
    let memS = MemorySampler()
    let gpuS = GPUSampler()
    _ = cpuS.next()                      // 建基准
    gpuS.prime()
    Thread.sleep(forTimeInterval: 2.2)   // 跨过 GPU 的 2s 采样间隔

    var s = Sample()
    s.cpu = cpuS.next() ?? 0
    s.gpu = gpuS.next()
    let mem = memS.next()
    let d = memS.last
    s.memPct = mem.pct; s.memUsedGB = mem.usedGB; s.memTotalGB = mem.totalGB
    s.memAppGB = d.appGB; s.memWiredGB = d.wiredGB; s.memCompressedGB = d.compressedGB
    s.memCachedGB = d.cachedGB; s.memFreeGB = d.freeGB
    s.swapUsedGB = swapUsedGB()
    s.memPressurePct = d.totalGB > 0 ? min(100, (d.compressedGB + s.swapUsedGB) / d.totalGB * 100) : 0

    let fixed = s
    let ctl = ProcessWindowController()
    ctl.sampleProvider = { fixed }
    ctl.show()
    // 引擎探测走后台队列 + 回主队列：主队列必须有 runloop 运行才会执行，sleep 不行
    RunLoop.main.run(until: Date().addingTimeInterval(3.0))
    // --demo-models：注入覆盖全状态的快照（加载中 / 故障 现场很难正好撞上），用于验收配色与文案
    if CommandLine.arguments.contains("--demo-models") {
        var demo = ModelSnapshot()
        demo.enginesFound = 1
        demo.rows = [
            ModelRow(name: "Some-New-Video-Model-8bit", memGB: 28.06, state: .running,
                     note: "引擎 A · 正在处理请求"),
            ModelRow(name: "org/Another-New-Weight-Q5", memGB: 12.30, state: .loading,
                     note: "引擎 A · 权重正在加载，暂不接请求"),
            ModelRow(name: "Unmapped-State-Model", memGB: 0, state: .uncertain,
                     note: "引擎 A · 引擎自报状态「warmup-x」，这个值还不认识"),
            ModelRow(name: "Broken-Weight", memGB: 0, state: .failed,
                     note: "引擎 A · 该模型加载失败（服务端日志有原因）"),
        ]
        demo.unloaded = ["Unused-Weight-A", "Unused-Weight-B", "Unused-Weight-C", "Unused-Weight-D"]
        ctl.selfCheckInjectModels(demo)
    }
    let ok = ctl.selfCheckRenderPNG(to: out)
    print(ok ? "panel=\(out)" : "panel=失败（窗口没建起来？）")
    exit(ok ? 0 : 1)
}

// 单实例：用**文件锁**，不用 pid 比较。
// 踩过：LaunchAgent 的 RunAtLoad 与 Dock 的登录恢复几乎同时拉起两份，
// 两边用 runningApplications 查对方时可能都还查不到，于是两份都活下来、各画一个 Dock 图标。
// flock 是内核仲裁，谁先拿到谁活；后到的那份激活前者再退出。
// （plist 的 KeepAlive.SuccessfulExit=false 只对非零退出生效，正常 exit(0) 不会被拉起。）
// 自检模式带参数，不参与。
var instanceLockFD: Int32 = -1
if CommandLine.arguments.count <= 1 {
    let lockDir = NSHomeDirectory() + "/Library/Application Support/Dockolate"
    try? FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
    instanceLockFD = open(lockDir + "/instance.lock", O_CREAT | O_RDWR, 0o600)
    if instanceLockFD >= 0, flock(instanceLockFD, LOCK_EX | LOCK_NB) != 0 {
        if let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != getpid() }) {
            other.activate(options: [.activateIgnoringOtherApps])
        }
        exit(0)
    }
    // 拿到锁就把 fd 一直留着：进程退出时内核自动释放，不写 pid 文件、不留垃圾
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .regular：Dock 里出现可点击的应用图标（而非仅菜单栏的 accessory）
app.setActivationPolicy(.regular)
app.run()
