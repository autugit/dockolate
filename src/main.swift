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
    var memPct: Double = 0         // 0...100
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
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

final class MemorySampler {
    private let totalBytes: Double
    private var pageSize: Double = 16384

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
        let active = Double(stats.active_count) * pageSize
        let wired  = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let used = active + wired + compressed
        let pct = totalBytes > 0 ? min(100, used / totalBytes * 100) : 0
        return (pct, used / 1_073_741_824, totalBytes / 1_073_741_824)
    }
}

// ============================================================
// MARK: - GPU（IOAccelerator → PerformanceStatistics）
// 免 root。ioreg 为短命子进程，约 10–20 ms/次，故单独用较长采样间隔。
// ============================================================

final class GPUSampler {
    private var cached: Double? = nil
    private var lastRead = Date.distantPast
    private let interval: TimeInterval = 2.0

    func next() -> Double? {
        let now = Date()
        if now.timeIntervalSince(lastRead) < interval { return cached }
        lastRead = now
        cached = GPUSampler.read()
        return cached
    }

    /// 强制读一次（用于启动时立即取数）
    static func read() -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-d", "1", "-c", "IOAccelerator", "-w", "0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // 取第一个出现的 "Device Utilization %"=NN
        guard let r = text.range(of: "\"Device Utilization %\"=") else { return nil }
        let digits = text[r.upperBound...].prefix(while: { $0.isNumber })
        guard let v = Double(digits) else { return nil }
        return min(100, max(0, v))
    }
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
    case ..<50:  return NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)  // 绿
    case ..<80:  return NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1)  // 黄
    default:     return NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.28, alpha: 1)  // 红
    }
}

// ============================================================
// MARK: - Dock 图标绘制
// ============================================================

func pctNumber(_ v: Double) -> String { String(format: "%.0f", v) }

/// 格子里画：淡底 → 大号半透明水印字母（压在数字后面）→ 居中大数字（可带前缀）→ 底部细进度条
/// - watermark: 上排 C / G，作为背景大字
/// - prefix:    下排 "M"，作为数字前缀
func drawCell(_ r: NSRect,
              watermark: String? = nil,
              prefix: String? = nil,
              number: String,
              pct: Double,
              color: NSColor,
              maxFontSize: CGFloat) {

    let box = NSBezierPath(roundedRect: r, xRadius: 19, yRadius: 19)
    color.withAlphaComponent(0.13).setFill()
    box.fill()
    color.withAlphaComponent(0.45).setStroke()
    box.lineWidth = 1.5
    box.stroke()

    // 水印大字（裁到格子内，半透明，压在大数字后面）
    if let wm = watermark {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 19, yRadius: 19).addClip()
        let wAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r.height * 1.0, weight: .black),
            .foregroundColor: color.withAlphaComponent(0.20),
        ]
        let ws = (wm as NSString).size(withAttributes: wAttrs)
        (wm as NSString).draw(at: NSPoint(x: r.midX - ws.width / 2, y: r.midY - ws.height / 2),
                              withAttributes: wAttrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    // 底部细进度条
    let barH: CGFloat = 7
    let barPad: CGFloat = 10
    let trackRect = NSRect(x: r.minX + barPad, y: r.minY + 8,
                           width: r.width - barPad * 2, height: barH)
    let track = NSBezierPath(roundedRect: trackRect, xRadius: barH / 2, yRadius: barH / 2)
    NSColor(calibratedWhite: 1.0, alpha: 0.15).setFill()
    track.fill()
    let frac = CGFloat(min(100, max(0, pct)) / 100)
    if frac > 0.001 {
        let w = max(barH, trackRect.width * frac)
        let f = NSBezierPath(roundedRect: NSRect(x: trackRect.minX, y: trackRect.minY,
                                                 width: w, height: barH),
                             xRadius: barH / 2, yRadius: barH / 2)
        color.setFill()
        f.fill()
    }

    // 大号数字：宽、高双重约束下取最大字号，保证「100%」不溢出
    let maxW = r.width - 12
    let maxH = r.height - barH - 16

    func build(_ size: CGFloat) -> (NSMutableAttributedString, CGFloat, CGFloat) {
        let m = NSMutableAttributedString()
        if let p = prefix {
            m.append(NSAttributedString(string: p + " ", attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.62, weight: .black),
                .foregroundColor: color.withAlphaComponent(0.58),
            ]))
        }
        m.append(NSAttributedString(string: number, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy),
            .foregroundColor: color,
        ]))
        m.append(NSAttributedString(string: "%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.40, weight: .bold),
            .foregroundColor: color.withAlphaComponent(0.85),
        ]))
        let sz = m.size()
        return (m, sz.width, sz.height)
    }

    var size = maxFontSize
    var (att, w, h) = build(size)
    var guardCount = 0
    while (w > maxW || h > maxH) && size > 9 && guardCount < 40 {
        let k = min(maxW / max(w, 1), maxH / max(h, 1))
        size *= (k < 1 ? max(k * 0.98, 0.5) : 0.9)
        (att, w, h) = build(size)
        guardCount += 1
    }

    let bandBot = r.minY + barH + 16
    let y = (r.maxY + bandBot) / 2 - h / 2
    att.draw(at: NSPoint(x: r.midX - w / 2, y: y))
}

// MARK: Dock 图标（256×256：上二下一 · 大号数字 · C/G 水印 M 前缀）
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
        let topY = side - margin - cellH
        let botY = margin

        let cpuRect = NSRect(x: margin, y: topY, width: cellW, height: cellH)
        let gpuRect = NSRect(x: margin + cellW + gap, y: topY, width: cellW, height: cellH)
        let memRect = NSRect(x: margin, y: botY, width: inner, height: cellH)

        drawCell(cpuRect, watermark: "C", number: pctNumber(s.cpu),
                 pct: s.cpu, color: levelColor(s.cpu), maxFontSize: 80)

        if let g = s.gpu {
            drawCell(gpuRect, watermark: "G", number: pctNumber(g),
                     pct: g, color: levelColor(g), maxFontSize: 80)
        } else {
            drawCell(gpuRect, watermark: "G", number: "—", pct: 0,
                     color: NSColor(calibratedWhite: 0.50, alpha: 1), maxFontSize: 80)
        }

        drawCell(memRect, prefix: "M", number: pctNumber(s.memPct),
                 pct: s.memPct, color: levelColor(s.memPct), maxFontSize: 96)

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

    func topMemory(_ n: Int = 3) -> [ProcStat] {
        // rss 单位 KB → bytes
        psTop(n, sortFlag: "-m", valueKey: "rss").map {
            ProcStat(pid: $0.pid, name: $0.name, value: $0.value * 1024)
        }
    }

    // ---------- GPU：AGXDeviceUserClient 的 accumulatedGPUTime 增量 ----------
    // 每个 GPU 用户客户端实例的 IOUserClientCreator 就是持有进程，
    // AppUsage 里累积了该客户端的 GPU 时间（纳秒）。
    // 两次采样求差 ÷ 墙钟 ⇒ 该进程占用了多少个「整颗 GPU」的算力。
    private var gpuPrev: [Int32: (name: String, t: Int)] = [:]
    private var gpuPrevAt = Date()
    private var gpuCached: [ProcStat] = []

    private func readGPUclients() -> [Int32: (name: String, t: Int)] {
        guard let out = ProcessSampler.run("/usr/sbin/ioreg",
                ["-r", "-c", "AGXDeviceUserClient", "-l", "-w", "0"]) else { return [:] }
        var res: [Int32: (name: String, t: Int)] = [:]
        let blocks = out.components(separatedBy: "+-o AGXDeviceUserClient")
        for b in blocks.dropFirst() {
            guard let r = b.range(of: "\"IOUserClientCreator\" = \"pid "),
                  let comma = b[r.upperBound...].firstIndex(of: ","),
                  let pid = Int32(b[r.upperBound..<comma]) else { continue }
            let afterComma = b[b.index(after: comma)...]
            guard let q = afterComma.firstIndex(of: "\"") else { continue }
            let name = String(afterComma[..<q]).trimmingCharacters(in: .whitespaces)

            var total = 0
            var idx = b.startIndex
            while let rr = b.range(of: "\"accumulatedGPUTime\"=", range: idx..<b.endIndex) {
                let digits = b[rr.upperBound...].prefix(while: { $0.isNumber })
                if let v = Int(digits) { total += v }
                if digits.endIndex <= rr.upperBound { break }
                idx = digits.endIndex
            }
            let prev = res[pid]
            res[pid] = (prev?.name ?? name, (prev?.t ?? 0) + total)
        }
        return res
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

        // 三段排行
        section("CPU 占用最高", top: 396, into: content)
        for i in 0..<3 { row(y: 370 - CGFloat(i) * 26, into: content) }
        section("GPU 占用最高", top: 286, into: content)
        for i in 0..<3 { row(y: 260 - CGFloat(i) * 26, into: content) }
        section("内存占用最高（常驻 RSS）", top: 176, into: content)
        for i in 0..<3 { row(y: 150 - CGFloat(i) * 26, into: content) }

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
            summaryLabel?.stringValue = String(format: "CPU %.0f%%　·　GPU %@　·　内存 %.1f / %.0f GB（%.0f%%）",
                                               s.cpu, gpu, s.memUsedGB, s.memTotalGB, s.memPct)
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

        // 先读一次 GPU（预热缓存），CPU 需要两次才能算增量
        let _ = GPUSampler.read()

        buildMenu()
        status.item.isVisible = false          // 菜单栏读数默认隐藏

        // 首次采样：GPU/内存立刻有值，CPU 需要两拍才有增量
        if let g = GPUSampler.read() { target.gpu = g; display.gpu = g }
        let m0 = memSampler.next()
        target.memPct = m0.pct; target.memUsedGB = m0.usedGB; target.memTotalGB = m0.totalGB
        display.memPct = m0.pct; display.memUsedGB = m0.usedGB; display.memTotalGB = m0.totalGB
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
        if let g = gpuSampler.next() { target.gpu = g }
    }

    /// 2) 每 0.25 秒把显示值向真实值插值 → Dock 图标平滑滑动，而不是一秒一跳
    func animate() {
        let k = 0.35
        var s = Sample()
        s.cpu = display.cpu + (target.cpu - display.cpu) * k
        s.memPct = display.memPct + (target.memPct - display.memPct) * k
        s.memUsedGB = target.memUsedGB
        s.memTotalGB = target.memTotalGB
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
    print("=== 内存占用最高（常驻 RSS）===")
    for s in mem { print(String(format: "  %-32s %6.2f GB  (pid %d)", (s.name as NSString).utf8String!, s.value / 1_073_741_824, s.pid)) }
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

    _ = cpuS.next()                      // 建基准
    let gpuA = GPUSampler.read()
    Thread.sleep(forTimeInterval: 1.0)
    let cpu = cpuS.next() ?? 0
    let mem = memS.next()
    let gpuB = gpuS.next() ?? gpuA

    var s = Sample()
    s.cpu = cpu
    s.gpu = gpuB
    s.memPct = mem.pct
    s.memUsedGB = mem.usedGB
    s.memTotalGB = mem.totalGB

    // --mock=CPU,GPU,MEM：强制指定显示数值，用于验收边界态（如 100/100/100）
    if let mock = CommandLine.arguments.first(where: { $0.hasPrefix("--mock=") }) {
        let parts = mock.replacingOccurrences(of: "--mock=", with: "")
            .split(separator: ",").compactMap { Double($0) }
        if parts.count == 3 {
            s.cpu = parts[0]; s.gpu = parts[1]; s.memPct = parts[2]
        }
    }

    print(String(format: "cpu=%.1f gpu=%@ mem=%.1f%% (%.1f/%.0f GB) chip=%@",
                 s.cpu,
                 s.gpu.map { String(format: "%.1f", $0) } ?? "nil",
                 s.memPct, s.memUsedGB, s.memTotalGB, gpuName()))

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
