// ============================================================
// 内存池条（AI 管理页顶部）
// ============================================================
//
// 用户裁定（2026-10-29）：
//   · 池子总长 = 物理内存，超过它的一律不画进池内
//   · 系统 / 其他 / 预留 / 各模型 / 空余 分段；预留必须画出来
//   · 换页溢出的部分接在池外，不并入总量
//   · 模型按实际驻留量占池；「未进池」的部分从池顶凸出（不占横向长度）
//   · GPU 可用上限画一条虚线（Metal 能给的上限通常低于物理内存）
//
// 口径：
//   模型驻留 = 引擎 /metrics 的 hardware.ram_used（引擎自报，最权威）
//   池内「系统与其他」= 已用总量（MemoryMath 口径）− 模型驻留之和
//   凸出量 = 权重体积 − 驻留量（含 mmap 到 SSD 的层，属正常）

import Foundation
import AppKit
import Metal

final class MemoryPoolBar: NSView {

    struct ModelSlot {
        let name: String
        let residentGiB: Double       // 引擎自报驻留
        let weightGiB: Double         // 权重体积（磁盘）
        let isRunning: Bool
    }

    // 输入
    private var totalGiB: Double = 0
    private var usedGiB: Double = 0          // MemoryMath 口径的「已用」
    private var reserveGiB: Double = 6
    private var gpuLimitGiB: Double = 0
    private var swapGiB: Double = 0
    private var slots: [ModelSlot] = []
    // 已用内存的分解（用户要求：系统 / 其他 / 压缩 各占一段，不再合并成一块）
    private var wiredGiB: Double = 0        // 系统（内核联动，不可压缩）
    private var appGiB: Double = 0          // 应用内存（含模型驻留，绘制时扣掉）
    private var compressedGiB: Double = 0   // 压缩器

    private let barHeight: CGFloat = 44
    private let overhangMax: CGFloat = 26

    override var isFlipped: Bool { false }

    // ---------- 数据 ----------

    func update(totalGiB: Double, usedGiB: Double, reserveGiB: Double,
                swapGiB: Double, wiredGiB: Double = 0, appGiB: Double = 0,
                compressedGiB: Double = 0, slots: [ModelSlot]) {
        self.wiredGiB = max(0, wiredGiB)
        self.appGiB = max(0, appGiB)
        self.compressedGiB = max(0, compressedGiB)
        self.totalGiB = max(1, totalGiB)
        self.usedGiB = max(0, usedGiB)
        self.reserveGiB = max(0, reserveGiB)
        self.swapGiB = max(0, swapGiB)
        self.slots = slots
        self.gpuLimitGiB = Self.metalLimitGiB()
        needsDisplay = true
    }

    /// Metal 能给的上限（Apple Silicon 上通常约为物理内存的 78–82%）
    static func metalLimitGiB() -> Double {
        guard let dev = MTLCreateSystemDefaultDevice() else { return 0 }
        return Double(dev.recommendedMaxWorkingSetSize) / 1_073_741_824
    }

    /// 进程 RSS（GiB）。池子/方块用这个口径：mmap 进来的权重页确实占着内存，
    /// `ri_phys_footprint` 不算它们（实测 125B：footprint 18 GB ↔ RSS 进程树 RSS 的大头），
    /// 会把最大那块模型错记成「系统与其他」。
    static func rssGiB(pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz)
        guard got == sz else { return nil }
        return Double(info.pti_resident_size) / 1_073_741_824
    }

    /// 进程**树**的 RSS（GiB）：启动器（server.py / bash 包装）自己只有几百 MB，
    /// 真正吃内存的是它的引擎子进程（strata / mlx-serve / python main.py）。
    /// 只算 e.pid 会把 60 GB 的模型记成 0.3 GB。
    static func subtreeRSSGiB(rootPid: pid_t) -> Double? {
        var seen = Set<pid_t>()
        var total = 0.0
        var queue = [rootPid]
        var found = false
        while let pid = queue.popLast() {
            if seen.contains(pid) { continue }
            seen.insert(pid)
            if let rss = rssGiB(pid: pid) { total += rss; found = true }
            let n = proc_listchildpids(pid, nil, 0)
            guard n > 0 else { continue }
            var kids = [pid_t](repeating: 0, count: Int(n))
            let got = proc_listchildpids(pid, &kids, Int32(kids.count * MemoryLayout<pid_t>.size))
            guard got > 0 else { continue }
            queue.append(contentsOf: kids.prefix(Int(got)))
        }
        return found ? total : nil
    }

    /// 引擎自报的 RAM 用量（/metrics → hardware.ram_used），单位 GiB。
    /// 用户裁定：池内模型段用这个数，不用面板里那套 23.56 GB 的口径。
    static func engineResidentGiB(port: Int?) -> Double? {
        guard let port, port > 0,
              let obj = LocalHTTP.json(port: port, path: "/metrics") as? [String: Any] else { return nil }
        let hw = (obj["hardware"] as? [String: Any]) ?? obj
        for key in ["ram_used", "gpu_mem_used"] {
            if let v = (hw[key] as? NSNumber)?.doubleValue, v > 0 {
                return v / 1_073_741_824
            }
        }
        return nil
    }

    /// 已换出到 swap 的容量（sysctl vm.swapusage）
    static func swapUsedGiB() -> Double {
        var size = 0
        guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("vm.swapusage", &buf, &size, nil, 0) == 0 else { return 0 }
        let text = String(cString: buf)
        // 形如 "total = 2048.00M  used = 512.00M  free = 1536.00M"
        guard let usedRange = text.range(of: "used = ") else { return 0 }
        let rest = text[usedRange.upperBound...]
        let numberPart = rest.prefix { "0123456789.".contains($0) }
        let unit = rest.dropFirst(numberPart.count).first ?? "M"
        guard let value = Double(numberPart) else { return 0 }
        let scale: Double = unit == "G" ? 1 : (unit == "K" ? 1.0 / 1_048_576 : 1.0 / 1024)
        return value * scale
    }

    // ---------- 绘制 ----------
    //
    // 三层布局（用户裁定后重构，避免文字互相压）：
    //   y 86–102  顶部：左「物理内存 NN GB」· 右「图例」
    //   y 58–84   凸出区：模型未驻留的部分从池顶往上生长
    //   y 14–58   池体：系统 / 模型 / 预留 / 空余 分段
    //   y  0–12   底部刻度：0 · GPU 上限 · 总容量

    private let legendH: CGFloat = 16
    private let axisH: CGFloat = 14
    private var barBottom: CGFloat { axisH }
    private var barTop: CGFloat { axisH + barHeight }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard totalGiB > 0, w > 60 else { return }

        let ppg = w / CGFloat(totalGiB)
        let label = NSFont.systemFont(ofSize: 10, weight: .medium)
        let tiny = NSFont.systemFont(ofSize: 9, weight: .regular)

        func text(_ str: String, in r: NSRect, font: NSFont = label,
                  color: NSColor, align: NSTextAlignment = .center) {
            let style = NSMutableParagraphStyle()
            style.alignment = align
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: str, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]).draw(in: r)
        }

        let bar = NSRect(x: 0, y: barBottom, width: w, height: barHeight)

        // ---- 池体底 ----
        let bg = NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.28).setFill()
        bg.fill()

        var x: CGFloat = 0

        // 已用内存拆三段：系统（联动）/ 其他应用 / 压缩
        // ⛔ 三段必须刚好填满「已用 − 模型」，否则池条右边会露出一块背景灰
        //    （用户 2026-11-01 问的「最右边的灰色块」就是它：不是内存类别，是没画满）。
        // 权重取 wired / (应用 − wired) / 压缩：应用内存里已含 wired 与模型的页，
        // 减掉 wired 才不重复计数；再按权重把「已用 − 模型」的余量分完。
        let residentSum = slots.filter(\.isRunning).reduce(0) { $0 + $1.residentGiB }
        let remainder = max(0, usedGiB - residentSum)
        let wSystem = max(0, wiredGiB)
        let wOther = max(0, appGiB - wiredGiB)
        let wComp = max(0, compressedGiB)
        let wSum = wSystem + wOther + wComp
        let partSystem = wSum > 0.01 ? remainder * wSystem / wSum : remainder
        let partOther = wSum > 0.01 ? remainder * wOther / wSum : 0
        let partComp = wSum > 0.01 ? remainder * wComp / wSum : 0

        func drawSegment(_ giB: Double, _ color: NSColor, _ title: String?, _ titleColor: NSColor) {
            guard giB > 0.02 else { return }
            let seg = NSRect(x: x, y: barBottom, width: CGFloat(giB) * ppg, height: barHeight)
            color.setFill()
            NSBezierPath(rect: seg).fill()
            if let t = title, seg.width > 64 {
                text(t, in: seg.insetBy(dx: 4, dy: barHeight / 2 - 7), font: tiny, color: titleColor)
            }
            x += seg.width
        }

        drawSegment(partSystem, NSColor(calibratedWhite: 0.42, alpha: 1),
                    "系统 \(fmt(partSystem))", .white)
        drawSegment(partOther, NSColor(calibratedWhite: 0.62, alpha: 1),
                    "其他 \(fmt(partOther))", .white)
        drawSegment(partComp, NSColor.systemPurple.withAlphaComponent(0.35),
                    "压缩 \(fmt(partComp))", .black)

        // 各运行中的模型
        var slotRects: [(NSRect, ModelSlot)] = []
        var residentBudget = max(0, usedGiB - partSystem - partOther - partComp)
        for m in slots where m.isRunning && m.residentGiB > 0.05 {
            let drawGiB = min(m.residentGiB, residentBudget > 0.05 ? residentBudget : m.residentGiB)
            residentBudget -= drawGiB
            let seg = NSRect(x: x, y: barBottom, width: CGFloat(drawGiB) * ppg, height: barHeight)
            NSColor.systemBlue.withAlphaComponent(0.80).setFill()
            NSBezierPath(rect: seg).fill()
            if seg.width > 84 {
                // 只用主名（去掉 " · IQ3_S" 这类后缀），否则宽段也会被省略号吃掉
                let short = m.name.components(separatedBy: " · ").first ?? m.name
                text("\(short) 驻留 \(fmt(m.residentGiB))",
                     in: seg.insetBy(dx: 4, dy: barHeight / 2 - 7), font: tiny, color: .white)
            }
            slotRects.append((seg, m))
            x += seg.width
        }

        // 预留（斜纹）
        if reserveGiB > 0.05 {
            let seg = NSRect(x: x, y: barBottom, width: CGFloat(reserveGiB) * ppg, height: barHeight)
            NSColor.systemOrange.withAlphaComponent(0.26).setFill()
            NSBezierPath(rect: seg).fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: seg).addClip()
            var hx = seg.minX - barHeight
            while hx < seg.maxX {
                let pth = NSBezierPath()
                pth.move(to: NSPoint(x: hx, y: seg.minY))
                pth.line(to: NSPoint(x: hx + barHeight, y: seg.maxY))
                pth.lineWidth = 1
                NSColor.systemOrange.withAlphaComponent(0.55).setStroke()
                pth.stroke()
                hx += 6
            }
            NSGraphicsContext.restoreGraphicsState()
            if seg.width > 50 {
                text("预留 \(fmt(reserveGiB))", in: seg.insetBy(dx: 2, dy: barHeight / 2 - 7), color: .black)
            }
            x += seg.width
        }

        // 空余
        let freeGiB = max(0, totalGiB - usedGiB - reserveGiB)
        if freeGiB > 0.05 {
            let seg = NSRect(x: x, y: barBottom, width: CGFloat(freeGiB) * ppg, height: barHeight)
            NSColor.systemGreen.withAlphaComponent(0.20).setFill()
            NSBezierPath(rect: seg).fill()
            if seg.width > 66 {
                text("空余 \(fmt(freeGiB))", in: seg.insetBy(dx: 4, dy: barHeight / 2 - 7),
                     color: .secondaryLabelColor)
            }
        }

        // ---- 凸出水面：同一方块向上生长，与池内段无缝 ----
        for (seg, m) in slotRects {
            let missing = max(0, m.weightGiB - m.residentGiB)
            guard missing > 0.05 else { continue }
            let ratio = min(1.0, CGFloat(missing / max(m.weightGiB, 0.01)))
            let h = max(5, ratio * overhangMax)
            let over = NSRect(x: seg.minX, y: barTop, width: seg.width, height: h)
            NSColor.systemBlue.withAlphaComponent(0.26).setFill()
            NSBezierPath(rect: over).fill()
            // 左右竖边（让「这是一个方块伸出水面」读得出来，而不是浮框）
            NSColor.systemBlue.withAlphaComponent(0.55).setStroke()
            let sides = NSBezierPath()
            sides.move(to: NSPoint(x: over.minX + 0.5, y: over.minY))
            sides.line(to: NSPoint(x: over.minX + 0.5, y: over.maxY))
            sides.move(to: NSPoint(x: over.maxX - 0.5, y: over.minY))
            sides.line(to: NSPoint(x: over.maxX - 0.5, y: over.maxY))
            sides.lineWidth = 1
            sides.stroke()
            let top = NSBezierPath()
            top.move(to: NSPoint(x: over.minX, y: over.maxY))
            top.line(to: NSPoint(x: over.maxX, y: over.maxY))
            top.lineWidth = 1.5
            top.stroke()
            if over.width > 150 {
                text("未驻留 \(fmt(missing))", in: NSRect(x: over.minX + 5, y: over.maxY - 13,
                                                       width: over.width - 10, height: 12),
                     font: tiny, color: .secondaryLabelColor, align: .left)
            }
        }

        // ---- GPU 上限虚线（贯穿池体与凸出区）----
        if gpuLimitGiB > 0.1 && gpuLimitGiB < totalGiB {
            // 只画在水面之上：GPU 上限约束的是「模型能占多少」，不是「总量轴上的位置」，
            // 画穿池体会让人误读成「系统占用越过了 GPU 上限」。
            let gx = CGFloat(gpuLimitGiB) * ppg
            let pth = NSBezierPath()
            pth.move(to: NSPoint(x: gx, y: barTop))
            pth.line(to: NSPoint(x: gx, y: barTop + overhangMax))
            pth.lineWidth = 1
            pth.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.systemPurple.withAlphaComponent(0.8).setStroke()
            pth.stroke()
        }

        // ---- 水面线（池顶）：凸出块从这条线往上长 ----
        let waterline = NSBezierPath()
        waterline.move(to: NSPoint(x: 0.5, y: barTop))
        waterline.line(to: NSPoint(x: w - 0.5, y: barTop))
        waterline.lineWidth = 1.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        waterline.stroke()

        // ---- 池体边框 ----
        let border = NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        NSColor.separatorColor.setStroke()
        border.stroke()

        // ---- 底部刻度 ----
        text("0", in: NSRect(x: 1, y: 0, width: 20, height: 12), font: tiny,
             color: .tertiaryLabelColor, align: .left)
        text(fmt(totalGiB), in: NSRect(x: w - 70, y: 0, width: 68, height: 12), font: tiny,
             color: .secondaryLabelColor, align: .right)
        if gpuLimitGiB > 0.1 && gpuLimitGiB < totalGiB {
            let gx = CGFloat(gpuLimitGiB) * ppg
            text(String(format: "GPU 可用上限 %.1f GB", gpuLimitGiB),
                 in: NSRect(x: gx - 56, y: 0, width: 112, height: 12), font: tiny,
                 color: .systemPurple)
        }

        // ---- 顶部：左「物理内存」右「图例」----
        let legendY = barTop + overhangMax + 2
        text("物理内存 \(fmt(totalGiB))", in: NSRect(x: 2, y: legendY, width: 160, height: 12),
             font: tiny, color: .secondaryLabelColor, align: .left)

        let legend: [(NSColor, String)] = [
            (NSColor(calibratedWhite: 0.42, alpha: 1), "系统"),
            (NSColor(calibratedWhite: 0.62, alpha: 1), "其他"),
            (NSColor.systemPurple.withAlphaComponent(0.35), "压缩"),
            (NSColor.systemBlue.withAlphaComponent(0.80), "模型驻留"),
            (NSColor.systemBlue.withAlphaComponent(0.26), "未驻留"),
            (NSColor.systemOrange.withAlphaComponent(0.26), "预留"),
            (NSColor.systemGreen.withAlphaComponent(0.20), "空余"),
        ]
        var lx = w - 2
        for (color, name) in legend.reversed() {
            let nameW = (name as NSString).size(withAttributes: [.font: tiny]).width
            let itemW = nameW + 13
            lx -= itemW
            if lx < 150 { break }
            let dot = NSRect(x: lx, y: legendY + 2, width: 7, height: 7)
            color.setFill()
            NSBezierPath(roundedRect: dot, xRadius: 2, yRadius: 2).fill()
            text(name, in: NSRect(x: lx + 10, y: legendY, width: nameW + 2, height: 12),
                 font: tiny, color: .secondaryLabelColor, align: .left)
            lx -= 8
        }

        // ---- swap 溢流：接在池外 ----
        if swapGiB > 0.05 {
            let swW = min(max(30, CGFloat(swapGiB) * ppg), 130)
            let sw = NSRect(x: w + 5, y: barBottom, width: swW, height: barHeight)
            NSColor.systemRed.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: sw, xRadius: 6, yRadius: 6).fill()
            let pth = NSBezierPath(roundedRect: sw, xRadius: 6, yRadius: 6)
            pth.setLineDash([3, 2], count: 2, phase: 0)
            pth.lineWidth = 1
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            pth.stroke()
            text("已换出 \(fmt(swapGiB))", in: sw.insetBy(dx: 3, dy: barHeight / 2 - 7),
                 font: tiny, color: .systemRed)
        }
    }

    private func fmt(_ g: Double) -> String {
        g >= 10 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: axisH + barHeight + overhangMax + legendH + 6)
    }
}
