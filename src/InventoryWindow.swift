// ============================================================
// 模型清单窗口（方案 M3 的界面面）
// ============================================================
//
// 主面板只有 4 行，装不下「盘上所有版本」。这一窗口给出完整清单：
// 正在跑 / 已装载 / 在盘未登记 / 待确认 —— 每行带量化、角色、盘占、内存、来源。
//
// 与主面板同样的取舍：手工摆位、不用 nib、不用 NSTableView（验收靠进程内 cacheDisplay 截图），
// 行数固定 12 行、超出的收进脚注。

import Cocoa

final class InventoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let queue = DispatchQueue(label: "io.github.autugit.dockolate.inventory", qos: .utility)
    private let watcher = EngineWatcher()
    private let inventory = ModelInventory()

    private var timer: Timer?
    private var scanning = false
    private var cached: InventorySnapshot?
    private var sampledAt = Date.distantPast

    private let rowLimit = 18    // 屏幕上方的可见行数上限；超出的收进脚注
    private var nameLabels: [NSTextField] = []
    private var stateLabels: [NSTextField] = []
    private var diskLabels: [NSTextField] = []
    private var memLabels: [NSTextField] = []
    private var summaryLabel: NSTextField?
    private var headerLabel: NSTextField?
    private var footnote: NSTextField?

    // ---------- 窗口 ----------
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
        let t = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopTimer()   // 窗口关了就不再扫盘
    }

    // ---------- 界面 ----------
    private func build() {
        let width: CGFloat = 660
        let height = CGFloat(120 + rowLimit * 22 + 72)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Dockolate — 本机模型清单"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)   // 固定浅色：截图验收与系统深色模式解耦
        w.delegate = self
        w.center()
        let content = NSView(frame: w.contentLayoutRect)
        w.contentView = content

        func label(_ s: String, font: NSFont, color: NSColor, frame: NSRect) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = font
            t.textColor = color
            t.lineBreakMode = .byTruncatingTail
            t.frame = frame
            content.addSubview(t)
            return t
        }

        let ink = NSColor.labelColor                 // 正文（跟随系统外观）
        let mid = NSColor.secondaryLabelColor        // 次要
        let faint = NSColor.tertiaryLabelColor       // 表头 / 脚注

        var y = height - 34
        _ = label("本机模型清单", font: .systemFont(ofSize: 13, weight: .semibold),
                  color: ink, frame: NSRect(x: 24, y: y, width: 280, height: 18))
        summaryLabel = label("正在清点…", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             color: mid, frame: NSRect(x: 24, y: y - 20, width: 612, height: 16))

        y -= 44
        headerLabel = label("名称", font: .systemFont(ofSize: 10, weight: .medium),
                            color: faint, frame: NSRect(x: 24, y: y, width: 320, height: 14))
        _ = label("状态", font: .systemFont(ofSize: 10, weight: .medium),
                  color: faint, frame: NSRect(x: 350, y: y, width: 80, height: 14))
        _ = label("在盘", font: .systemFont(ofSize: 10, weight: .medium),
                  color: faint, frame: NSRect(x: 440, y: y, width: 90, height: 14))
        _ = label("内存", font: .systemFont(ofSize: 10, weight: .medium),
                  color: faint, frame: NSRect(x: 536, y: y, width: 90, height: 14))

        y -= 10
        for i in 0..<rowLimit {
            let ry = y - CGFloat(i + 1) * 22
            nameLabels.append(label("", font: .systemFont(ofSize: 11.5), color: ink,
                                    frame: NSRect(x: 24, y: ry, width: 320, height: 16)))
            stateLabels.append(label("", font: .systemFont(ofSize: 11), color: mid,
                                     frame: NSRect(x: 350, y: ry, width: 84, height: 16)))
            diskLabels.append(label("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                    color: mid,
                                    frame: NSRect(x: 440, y: ry, width: 90, height: 16)))
            memLabels.append(label("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                   color: mid,
                                   frame: NSRect(x: 536, y: ry, width: 96, height: 16)))
        }

        footnote = label("", font: .systemFont(ofSize: 10), color: faint,
                         frame: NSRect(x: 24, y: 20, width: 612, height: 30))
        footnote?.maximumNumberOfLines = 2
        footnote?.lineBreakMode = .byWordWrapping

        window = w
    }

    // ---------- 数据 ----------
    /// 15 秒一次：后台扫（引擎 + 磁盘），主线程只渲染缓存
    private func refresh() {
        guard window != nil else { return }
        if cached == nil || Date().timeIntervalSince(sampledAt) >= 14 {
            if !scanning {
                scanning = true
                queue.async { [weak self] in
                    guard let self = self else { return }
                    _ = self.watcher.refresh()
                    let runtime = self.watcher.refresh()
                    let snap = self.inventory.build(runtime: runtime)
                    DispatchQueue.main.async {
                        self.cached = snap
                        self.sampledAt = Date()
                        self.scanning = false
                        self.render()
                    }
                }
            }
        }
        render()
    }

    private func render() {
        guard window != nil, let snap = cached else { return }
        summaryLabel?.stringValue = String(
            format: "在跑 %d · 已装载 %d · 在盘未登记 %d · 待确认 %d ｜ 盘上合计 %.1f GB",
            snap.runningCount, snap.idleCount, snap.unregisteredCount, snap.uncertainCount,
            snap.totalDiskGB)

        for i in 0..<rowLimit {
            guard i < nameLabels.count else { continue }
            if i < snap.rows.count {
                let r = snap.rows[i]
                nameLabels[i].stringValue = r.title
                stateLabels[i].stringValue = r.state.text
                stateLabels[i].textColor = r.state.color
                diskLabels[i].stringValue = r.diskGB > 0.01 ? String(format: "%.1f GB", r.diskGB) : "—"
                memLabels[i].stringValue = r.memGB > 0.01 ? String(format: "%.1f GB", r.memGB) : "—"
                let tip = r.detail + (r.note.isEmpty ? "" : "｜" + r.note)
                nameLabels[i].toolTip = tip
                stateLabels[i].toolTip = tip
                diskLabels[i].toolTip = tip
                memLabels[i].toolTip = tip
                [nameLabels[i], stateLabels[i], diskLabels[i], memLabels[i]].forEach { $0.isHidden = false }
            } else {
                [nameLabels[i], stateLabels[i], diskLabels[i], memLabels[i]].forEach {
                    $0.stringValue = ""
                    $0.isHidden = true
                }
            }
        }

        var foot = "扫描根：" + snap.scannedRoots.map {
            $0.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }.joined(separator: "、")
        if snap.rows.count > rowLimit { foot += "\n另有 \(snap.rows.count - rowLimit) 行未显示" }
        if snap.truncated { foot += "（清单已截断）" }
        footnote?.stringValue = foot
    }

    // ---------- 自检（无屏幕录制权限时的验收面） ----------
    func selfCheckInject(_ snap: InventorySnapshot) {
        cached = snap
        sampledAt = Date()
    }

    func selfCheckRenderPNG(to path: String) -> Bool {
        guard let w = window, let v = w.contentView else { return false }
        render()
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
}
