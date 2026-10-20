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

// MARK: Dock 图标（256×256 四宫格：左上 C · 右上 G · 左下 Z · 右下 M）
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

        // 左下 Z：内存压缩 + 换页
        drawWaterCell(NSRect(x: leftX, y: botY, width: cellW, height: cellH),
                      letter: "Z", pct: s.memPressurePct, color: levelColor(s.memPressurePct))

        // 右下 M：内存占用
        drawWaterCell(NSRect(x: rightX, y: botY, width: cellW, height: cellH),
                      letter: "M", pct: s.memPct, color: levelColor(s.memPct))

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
    private var toggleMenuBar: NSButton?

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

    private func section(_ title: String, top: CGFloat, into content: NSView) {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: 24, y: top, width: 340, height: 16)
        content.addSubview(t)
    }

    private func row(y: CGFloat, into content: NSView) {
        let name = NSTextField(labelWithString: "—")
        name.font = NSFont.systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 24, y: y, width: 270, height: 18)
        content.addSubview(name)

        let val = NSTextField(labelWithString: "")
        val.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        val.alignment = .right
        val.frame = NSRect(x: 300, y: y, width: 96, height: 18)
        content.addSubview(val)

        nameLabels.append(name)
        valueLabels.append(val)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 486),
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
        s.frame = NSRect(x: 24, y: 452, width: 200, height: 16)
        content.addSubview(s)

        let sum = NSTextField(labelWithString: "—")
        sum.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        sum.frame = NSRect(x: 24, y: 428, width: 372, height: 20)
        content.addSubview(sum)
        summaryLabel = sum

        // 内存分解：让「进程榜加起来才几个 GB」有处可解释
        let bd = NSTextField(labelWithString: "")
        bd.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        bd.textColor = .secondaryLabelColor
        bd.lineBreakMode = .byTruncatingTail
        bd.frame = NSRect(x: 24, y: 400, width: 372, height: 16)
        content.addSubview(bd)
        breakdownLabel = bd

        // 换页（压缩内存见上一行；图标上不显示这两项，只在这里看）
        let sw = NSTextField(labelWithString: "")
        sw.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        sw.textColor = .secondaryLabelColor
        sw.lineBreakMode = .byTruncatingTail
        sw.frame = NSRect(x: 24, y: 384, width: 372, height: 16)
        content.addSubview(sw)
        swapLabel = sw

        // 三段排行
        section("CPU 占用最高", top: 356, into: content)
        for i in 0..<3 { row(y: 330 - CGFloat(i) * 25, into: content) }
        section("GPU 占用最高", top: 246, into: content)
        for i in 0..<3 { row(y: 220 - CGFloat(i) * 25, into: content) }
        section("内存占用最高（物理占用，含共享页）", top: 136, into: content)
        for i in 0..<3 { row(y: 110 - CGFloat(i) * 25, into: content) }

        // 底部按钮
        let quit = NSButton(title: "退出 DockStats", target: self, action: #selector(quitApp))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 300, y: 24, width: 96, height: 28)
        content.addSubview(quit)

        let toggle = NSButton(title: "菜单栏读数", target: self, action: #selector(toggleMenuBarItem(_:)))
        toggle.bezelStyle = .rounded
        toggle.setButtonType(.pushOnPushOff)
        toggle.frame = NSRect(x: 24, y: 24, width: 110, height: 28)
        content.addSubview(toggle)
        toggleMenuBar = toggle

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
                format: "CPU %.0f%%　·　GPU %@　·　内存 %.0f%%（%.1f / %.0f GB）",
                s.cpu, gpu, s.memPct, s.memUsedGB, s.memTotalGB)
            breakdownLabel?.stringValue = String(
                format: "内存去向：应用 %.1f + 内核联动 %.1f + 压缩 %.1f GB ｜ 文件缓存 %.1f GB（可回收）｜ 空闲 %.1f GB",
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .regular：Dock 里出现可点击的应用图标（而非仅菜单栏的 accessory）
app.setActivationPolicy(.regular)
app.run()
