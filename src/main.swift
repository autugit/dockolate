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

/// 格子里画：淡色底 + 左上标签 + 居中大号数字（带小号 %）+ 底部细进度条
func drawCell(_ r: NSRect, label: String, number: String,
              pct: Double, color: NSColor, maxFontSize: CGFloat) {
    let box = NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15)
    color.withAlphaComponent(0.15).setFill()
    box.fill()
    color.withAlphaComponent(0.50).setStroke()
    box.lineWidth = 1.5
    box.stroke()

    let lAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.60),
    ]
    let ls = (label as NSString).size(withAttributes: lAttrs)
    (label as NSString).draw(at: NSPoint(x: r.minX + 9, y: r.maxY - ls.height - 6),
                             withAttributes: lAttrs)

    let barH: CGFloat = 6
    let barPad: CGFloat = 9
    let trackRect = NSRect(x: r.minX + barPad, y: r.minY + 7,
                           width: r.width - barPad * 2, height: barH)
    let track = NSBezierPath(roundedRect: trackRect, xRadius: barH / 2, yRadius: barH / 2)
    NSColor(calibratedWhite: 1.0, alpha: 0.16).setFill()
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

    // 大号数字：按可用宽度自动取最大能装下的字号，保证「100」也不溢出
    let maxW = r.width - 20
    func build(_ size: CGFloat) -> (NSMutableAttributedString, CGFloat, CGFloat) {
        let nAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy),
            .foregroundColor: color,
        ]
        let pAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.46, weight: .bold),
            .foregroundColor: color.withAlphaComponent(0.85),
        ]
        let m = NSMutableAttributedString(string: number, attributes: nAttrs)
        m.append(NSAttributedString(string: "%", attributes: pAttrs))
        let sz = m.size()
        return (m, sz.width, sz.height)
    }
    var size = maxFontSize
    var (att, w, h) = build(size)
    if w > maxW, w > 0 {
        size = max(size * maxW / w, 10)
        (att, w, h) = build(size)
    }

    let bandTop = r.maxY - 24
    let bandBot = r.minY + barH + 12
    let y = (bandTop + bandBot) / 2 - h / 2
    att.draw(at: NSPoint(x: r.midX - w / 2, y: y))
}

// MARK: Dock 图标（256×256：上二下一 · 大号数字）
func makeDockIcon(_ s: Sample) -> NSImage {
    let side: CGFloat = 256
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 54, yRadius: 54)
        NSColor(calibratedWhite: 0.085, alpha: 1.0).setFill()
        bg.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.11).setStroke()
        bg.lineWidth = 2
        bg.stroke()

        let margin: CGFloat = 32
        let gap: CGFloat = 12
        let inner = side - margin * 2
        let cellW = (inner - gap) / 2
        let cellH = cellW
        let topY = side - margin - cellH
        let botY = margin

        let cpuRect = NSRect(x: margin, y: topY, width: cellW, height: cellH)
        let gpuRect = NSRect(x: margin + cellW + gap, y: topY, width: cellW, height: cellH)
        let memRect = NSRect(x: margin, y: botY, width: inner, height: cellH)

        drawCell(cpuRect, label: "CPU", number: pctNumber(s.cpu),
                 pct: s.cpu, color: levelColor(s.cpu), maxFontSize: 50)

        if let g = s.gpu {
            drawCell(gpuRect, label: "GPU", number: pctNumber(g),
                     pct: g, color: levelColor(g), maxFontSize: 50)
        } else {
            drawCell(gpuRect, label: "GPU", number: "—", pct: 0,
                     color: NSColor(calibratedWhite: 0.50, alpha: 1), maxFontSize: 50)
        }

        drawCell(memRect, label: "MEM", number: pctNumber(s.memPct),
                 pct: s.memPct, color: levelColor(s.memPct), maxFontSize: 64)

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
// MARK: - 详情窗口（点击 Dock 图标 / 菜单项时出现）
// ============================================================

final class DetailWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var labels: [String: NSTextField] = [:]
    private let chip: String

    init(chip: String) { self.chip = chip; super.init() }

    func show() {
        if window == nil { build() }
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "DockStats"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let content = NSView(frame: w.contentLayoutRect)
        w.contentView = content

        var y: CGFloat = content.bounds.height - 54
        let title = NSTextField(labelWithString: "实时占用率")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 24, y: y - 4, width: 320, height: 24)
        content.addSubview(title)

        y -= 34
        for key in ["CPU", "GPU", "MEM"] {
            let name = NSTextField(labelWithString: key)
            name.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            name.textColor = .secondaryLabelColor
            name.frame = NSRect(x: 24, y: y, width: 60, height: 20)
            content.addSubview(name)

            let val = NSTextField(labelWithString: "—")
            val.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
            val.frame = NSRect(x: 84, y: y - 4, width: 270, height: 26)
            content.addSubview(val)
            labels[key] = val
            y -= 46
        }

        let note = NSTextField(labelWithString: "采样：CPU/内存 1 秒，GPU 1.5 秒\nGPU 数据源：IOAccelerator · \(chip)")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 24, y: 20, width: 330, height: 40)
        note.maximumNumberOfLines = 2
        content.addSubview(note)

        self.window = w
    }

    func update(_ s: Sample) {
        guard window != nil else { return }
        labels["CPU"]?.stringValue = String(format: "%.1f %%", s.cpu)
        labels["CPU"]?.textColor = levelColor(s.cpu)
        if let g = s.gpu {
            labels["GPU"]?.stringValue = String(format: "%.1f %%", g)
            labels["GPU"]?.textColor = levelColor(g)
        } else {
            labels["GPU"]?.stringValue = "不可读"
            labels["GPU"]?.textColor = .secondaryLabelColor
        }
        labels["MEM"]?.stringValue = String(format: "%.1f %%　(%.1f / %.0f GB)",
                                            s.memPct, s.memUsedGB, s.memTotalGB)
        labels["MEM"]?.textColor = levelColor(s.memPct)
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
    private var detail: DetailWindowController!
    private var timer: Timer?
    private var animator: Timer?
    private var lastIcon: NSImage?
    private var showDockIcon = true
    private var target = Sample()
    private var display = Sample()
    private var lastDrawn = Sample(cpu: -1, gpu: -1, memPct: -1, memUsedGB: 0, memTotalGB: 0)

    func applicationDidFinishLaunching(_ note: Notification) {
        detail = DetailWindowController(chip: gpuName())

        // 先读一次 GPU（预热缓存），CPU 需要两次才能算增量
        let _ = GPUSampler.read()

        buildMenu()
        status.item.isVisible = true

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

        let detailItem = NSMenuItem(title: "打开详情窗口", action: #selector(openDetail(_:)), keyEquivalent: "d")
        detailItem.target = self
        menu.addItem(detailItem)

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

        status.update(s)
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
        detail.update(s)
    }

    @objc private func toggleDock(_ sender: NSMenuItem) {
        showDockIcon.toggle()
        sender.state = showDockIcon ? .on : .off
        if showDockIcon { tick() }
    }

    @objc private func openDetail(_ sender: Any?) {
        detail.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // 点 Dock 图标（有/无窗口）都弹出详情
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        detail.show()
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
