// ============================================================
// 内存蓄水池（AI 管理页）
// ============================================================
//
// 用户设计（2026-11-03 第四轮，废弃冰山方案）：
//   · 蓄水池＝**固定大小**的**敞口水箱**：只画左右池壁与池底，顶部开口
//   · 自下而上：预留（最底，不可用）→ 压缩 → 系统内核 → 应用与其他 → 模型 → 空闲
//   · 剩余空间统一挪到最上面（贴着口沿＝容量线那块），统一用**绿色**
//   · 模型浮出池口（已用 > 物理内存）的部分画**红色**＝警告
//   · 未载入内存的权重（mmap 在 SSD）不再在池内凸起：放进池子**右侧下方的「池外」小箱子**，
//     颜色与池内同名模型一致、用同一个名字标明关联
//   · 色块高度 ≥ 阈值时块内居中写名称，低于阈值不写（名字仍在右侧图例里）
//   · 池内所有色块圆角矩形（r=3）+ 统一 3 pt 缝；薄块不缩缝、改小圆角
//   · 宽度统一：模型列与层块同一段可用宽度
//
// 口径：模型驻留 = 进程树 RSS（启动器 + 引擎子进程）。footprint 不计 mmap 的权重页
//       （实测 125B：18 GB ↔ RSS 进程树 RSS 的大头），会把最大的模型错记成「系统与其他」。

import AppKit

final class MemoryReservoirView: NSView {

    struct ModelSlot {
        let name: String
        let residentGiB: Double      // 已驻留（池内实心块）
        let weightGiB: Double        // 权重体积 ⇒ 未载入 = weight − resident（池外小箱）
        let color: NSColor           // 状态色（与管理器方块同一套）
    }

    // ---- 输入 ----
    private var totalGiB: Double = 0
    private var usedGiB: Double = 0
    private var reserveGiB: Double = 6
    private var wiredGiB: Double = 0
    private var compressedGiB: Double = 0
    private var swapGiB: Double = 0
    private var slots: [ModelSlot] = []

    // ---- 几何常量 ----
    private let tankHeight: CGFloat = 236          // 固定：敞口水箱高度（0…总容量）
    private let inset: CGFloat = 12
    private let tickW: CGFloat = 34
    private let gap: CGFloat = 3
    private let radius: CGFloat = 3
    private let legendWidth: CGFloat = 214
    private let boxWidthWide: CGFloat = 64         // 宽版：池外小箱放最左侧（原 96 → 64），明显缩小
    private let offBoxTickGap: CGFloat = 10        // 小箱与刻度列之间的缝
    private let offBoxHeightNarrow: CGFloat = 64   // 窄版：挪到池子下方，优先缩小
    private let legendBoxGap: CGFloat = 12

    // ---- 配色（差异要一眼分得开） ----
    private let cReserve  = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.30, alpha: 1)  // 预留：近黑蓝
    private let cCompress = NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.88, alpha: 1)  // 压缩：紫
    private let cKernel   = NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.28, alpha: 1)  // 系统内核：砖红
    private let cApp      = NSColor(calibratedRed: 0.52, green: 0.58, blue: 0.64, alpha: 1)  // 应用与其他：蓝灰
    private let cFree     = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)  // 空闲：绿（用户令）
    private let cOverflow = NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.24, alpha: 1)  // 溢出：红＝警告
    private let cWall     = NSColor(calibratedWhite: 0.70, alpha: 1)
    private let inkDark   = NSColor(calibratedWhite: 0.10, alpha: 1)

    override var isFlipped: Bool { true }

    // ---------- 数据 ----------

    func update(totalGiB: Double, usedGiB: Double, reserveGiB: Double, wiredGiB: Double,
                compressedGiB: Double, swapGiB: Double, slots: [ModelSlot]) {
        let oldHeight = viewHeight
        self.totalGiB = max(1, totalGiB)
        self.usedGiB = max(0, usedGiB)
        self.reserveGiB = max(0, reserveGiB)
        self.wiredGiB = max(0, wiredGiB)
        self.compressedGiB = max(0, compressedGiB)
        self.swapGiB = max(0, swapGiB)
        self.slots = slots
        if abs(viewHeight - oldHeight) > 0.5 { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    private struct LayerSums {
        let modelSum: Double
        let system: Double        // 系统（内核联动）
        let other: Double         // 应用与其他（不含模型）
        let compressed: Double
        let sediment: Double      // 沉底总量（含预留）
        let free: Double
    }

    /// 口径与顶部「内存池条」同一条（2026-11-01 用户裁定）：
    /// 权重取 wired / (应用 − wired) / 压缩，但这三项**按权重分「已用 − Σ模型」的余量**，
    /// 因此 系统 + 其他 + 压缩 ≡ 已用 − Σ模型，天然不会把模型的页重复算一次。
    /// （直接拿 wired 当系统量会重复计数：Metal 页既在 wired 里、又在模型 RSS 里，
    ///   实测在一台大内存机器上会算出 超过物理内存的合计（> 物理内存）⇒ 假溢出。）
    private func layers() -> LayerSums {
        let modelSum = slots.reduce(0) { $0 + $1.residentGiB }
        let remainder = max(0, usedGiB - modelSum)
        let wSystem = max(0, wiredGiB)
        let wOther = max(0, usedGiB - compressedGiB - wiredGiB)
        let wComp = max(0, compressedGiB)
        let wSum = wSystem + wOther + wComp
        let system = wSum > 0.01 ? remainder * wSystem / wSum : remainder
        let other = wSum > 0.01 ? remainder * wOther / wSum : 0
        let compressed = wSum > 0.01 ? remainder * wComp / wSum : 0
        let sediment = reserveGiB + system + other + compressed
        let free = max(0, totalGiB - sediment - modelSum)
        return LayerSums(modelSum: modelSum, system: system, other: other,
                         compressed: compressed, sediment: sediment, free: free)
    }

    // ---------- 高度 / 阈值 ----------

    /// 窄窗口断点：小于它就改成「池子在上、图例与池外小箱在下」的单列版式。
    /// 宽版要同时容下 刻度列 + 池外小箱(96) + 池子 + 图例(≥200)，
    /// 低于 620 时池子会被挤到画不出来（实测 420 pt 窗口两栏直接重叠）。
    private let narrowBreak: CGFloat = 620
    private var isStacked: Bool { bounds.width > 0 && bounds.width < narrowBreak }

    private var viewHeight: CGFloat {
        if isStacked {
            return inset + spillHeight + tankHeight
                + legendBoxGap + legendHeight(width: 0)
                + legendBoxGap + offBoxHeightNarrow + inset
        }
        // 宽版：池外小箱与池子同高、并排在左，纵向不再额外占位
        let lw = wideLegendWidth(bounds.width)
        return max(tankHeight + spillHeight + inset * 2, legendHeight(width: lw) + inset * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasStacked = bounds.width > 0 && bounds.width < narrowBreak
        super.setFrameSize(newSize)
        if wasStacked != (newSize.width > 0 && newSize.width < narrowBreak) {
            invalidateIntrinsicContentSize()
        }
    }

    /// 口沿之上给「溢出警告」留的高度：只有真的溢出时才留（水箱本身仍是固定大小）。
    private var spillHeight: CGFloat {
        let over = max(0, layers().sediment + layers().modelSum - totalGiB)
        guard over > 0.05 else { return 0 }
        let px = (tankHeight - 3) / max(0.001, totalGiB)
        return min(56, max(20, CGFloat(over) * px + 8))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: viewHeight)
    }

    /// 图例高度（行数与 drawLegend / drawLegendCompact 一一对应，改一处必须改另一处）
    /// 宽版图例的宽度（布局与高度估算共用同一条公式）
    private func wideLegendWidth(_ totalWidth: CGFloat) -> CGFloat {
        min(legendWidth, max(190, (totalWidth - inset * 2) * 0.30))
    }

    /// 图例行文字：名称过长时按英文分行惯例折行（空格 / 连字符处断），
    /// 因此每行高度要**量出来**，不能按固定 15 pt 估——否则图例与下方内容会叠。
    private func legendTextHeight(_ text: String, width: CGFloat, size: CGFloat, bold: Bool) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.hyphenationFactor = 1.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? DS.text(size, .semibold) : DS.text(size),
            .paragraphStyle: para,
        ]
        let r = (text as NSString).boundingRect(
            with: NSSize(width: max(20, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attrs)
        return max(size + 5, ceil(r.height) + 1)
    }

    private func legendHeight(width: CGFloat) -> CGFloat {
        if isStacked { return 15 + 4 + 15 * 2 }      // 一句总量 + 两行色块（窄到放不下时折行）
        let textW = width - 14                       // 减去左侧 9 pt 色块 + 5 pt 间距
        var h: CGFloat = 18 + 15                     // 标题 + 已用/空闲
        h += 5                                       // 段间距
        h += 15                                      // 空闲
        for s in slots.prefix(4) {                   // 模型行：名称可能折行
            h += legendTextHeight(String(format: "%.1f GB　%@", s.residentGiB, s.name),
                                  width: textW, size: 10, bold: false)
        }
        h += 15 * 4                                  // 应用 / 内核 / 压缩 / 预留
        if swapGiB > 0.05 { h += 2 + 15 }
        return h
    }

    /// 块内名称的最小高度：按字体量出来（行高 + 上下留白），不手填数字。
    private var labelFont: NSFont { DS.text(9.5, .semibold) }
    private var labelMinHeight: CGFloat {
        let f = labelFont
        return ceil(f.ascender - f.descender + f.leading) + 5
    }

    // ---------- 布局（draw 与 --dump-pool 共用同一份几何） ----------

    private enum BlockKind { case layer, model, free }

    private struct Block {
        let name: String
        let rect: NSRect
        let fill: NSColor
        let valueGB: Double
        let kind: BlockKind
    }

    private struct Layout {
        var tank = NSRect.zero
        var inner = NSRect.zero
        var legend = NSRect.zero
        var box = NSRect.zero
        var blocks: [Block] = []
        var overflows: [(name: String, rect: NSRect)] = []
        var overflowGB: Double = 0
        var offBlocks: [Block] = []
        var offTotal: Double = 0
        var labelMinHeight: CGFloat = 0
    }

    private func computeLayout(size: NSSize) -> Layout {
        var L = Layout()
        L.labelMinHeight = labelMinHeight

        let stacked = size.width > 0 && size.width < narrowBreak
        let legendW = stacked ? 0 : wideLegendWidth(size.width)
        if stacked {
            // 单列版式：刻度列 + 池子占满宽度，图例与池外小箱依次排在下面
            let tankX = tickW + inset
            let w = max(160, size.width - tankX - inset)
            L.tank = NSRect(x: tankX, y: inset + spillHeight, width: w, height: tankHeight)
            L.legend = NSRect(x: tankX, y: L.tank.maxY + legendBoxGap, width: w, height: legendHeight(width: 0))
            L.box = NSRect(x: tankX, y: L.legend.maxY + legendBoxGap, width: w, height: offBoxHeightNarrow)
        } else {
            let rx = size.width - inset - legendW
            // 2026-11-04 用户裁定：池外小箱挪到最左并明显缩小，刻度紧贴池子左壁——
            // 否则刻度画在小箱右边，看着像「池外池也只有 整机容量」。
            let boxX = inset
            let tankX = boxX + boxWidthWide + offBoxTickGap + tickW
            let tankW = max(180, rx - 14 - tankX)
            L.tank = NSRect(x: tankX, y: inset + spillHeight, width: tankW, height: tankHeight)
            // 瘦小箱：更窄更矮（高度 0.58×池子），底边与池底齐，绝不与池子等高
            L.box = NSRect(x: boxX, y: L.tank.minY, width: boxWidthWide,
                           height: max(46, tankHeight * 0.58))
            L.legend = NSRect(x: rx, y: inset, width: legendW, height: legendHeight(width: legendW))
        }
        L.inner = NSRect(x: L.tank.minX + 1.5, y: L.tank.minY + 1.5,
                         width: L.tank.width - 3, height: L.tank.height - 3)

        let sums = layers()
        let px = L.inner.height / max(0.001, totalGiB)
        func yGB(_ gb: Double) -> CGFloat { L.inner.maxY - CGFloat(gb) * px }

        var cursor = 0.0

        func addSlab(_ gb: Double, _ name: String, _ color: NSColor) {
            guard gb > 0.02 else { return }
            let top = yGB(cursor + gb)
            let bottom = yGB(cursor)
            cursor += gb
            let h = bottom - top
            var r = NSRect(x: L.inner.minX + 1, y: top, width: L.inner.width - 2, height: max(0.5, h))
            let rad: CGFloat
            if h < 4 {
                rad = min(1.5, max(0.5, h / 2))
            } else {
                r = NSRect(x: r.minX, y: r.minY + gap / 2, width: r.width, height: max(0.5, h - gap))
                rad = radius
            }
            L.blocks.append(Block(name: name, rect: r, fill: color, valueGB: gb, kind: .layer))
            _ = rad
        }

        // 沉底：预留（最底）→ 压缩 → 系统内核 → 应用与其他
        addSlab(reserveGiB, "预留", cReserve)
        addSlab(sums.compressed, "压缩", cCompress)
        addSlab(sums.system, "系统内核", cKernel)
        addSlab(sums.other, "应用与其他", cApp)

        // 模型：坐在沉淀之上，**按体积自下而上叠放**（竖直方向才是 GB 轴；
        // 并排多列会让各列起始高度错开、并在高处留出一块「无主」空白，读不出余量）
        let modelBase = cursor
        var colCursor = modelBase
        for s in slots {
            let bottomGB = colCursor
            let topGB = colCursor + s.residentGiB
            colCursor = topGB
            guard s.residentGiB > 0.02 else { continue }
            let bottomY = yGB(bottomGB) - gap / 2
            let topY = yGB(topGB) + gap / 2
            // 池内那部分（口沿以下）
            let insideTop = max(topY, L.inner.minY)
            if bottomY - insideTop > 0.5 {
                L.blocks.append(Block(name: s.name,
                                      rect: NSRect(x: L.inner.minX + 1, y: insideTop,
                                                   width: L.inner.width - 2, height: bottomY - insideTop),
                                      fill: s.color, valueGB: s.residentGiB, kind: .model))
            }
            // 浮出池口那部分：红色警告
            if topY < L.inner.minY - 0.5 {
                L.overflows.append((s.name, NSRect(x: L.inner.minX + 1, y: topY,
                                                   width: L.inner.width - 2,
                                                   height: L.inner.minY - topY)))
            }
        }
        cursor = colCursor
        L.overflowGB = max(0, cursor - totalGiB)

        // 空闲：模型之上、贴到口沿（＝容量线）的那一段，绿色
        if sums.free > 0.02 {
            let top = yGB(cursor + sums.free)
            let bottom = yGB(cursor) - gap / 2
            L.blocks.append(Block(name: "空闲",
                                  rect: NSRect(x: L.inner.minX + 1, y: top, width: L.inner.width - 2,
                                               height: max(0.5, bottom - top)),
                                  fill: cFree, valueGB: sums.free, kind: .free))
        }

        // 池外小箱：未载入内存的权重
        let offs: [(String, Double, NSColor)] = slots.compactMap { s in
            let v = max(0, s.weightGiB - s.residentGiB)
            return v > 0.05 ? (s.name, v, s.color) : nil
        }
        L.offTotal = offs.reduce(0) { $0 + $1.1 }
        if L.offTotal > 0.05 {
            if stacked {
                // 窄版：矮箱，按各自占比填满（不写名字）
                let headerH: CGFloat = 14
                let boxInner = NSRect(x: L.box.minX + 8, y: L.box.minY + headerH,
                                      width: L.box.width - 16,
                                      height: max(10, L.box.height - headerH - 6))
                let gaps = gap * CGFloat(max(0, offs.count - 1))
                let usableH = max(4, boxInner.height - gaps)
                var top = boxInner.minY
                for (name, v, color) in offs {
                    let h = max(0.5, usableH * CGFloat(v / L.offTotal))
                    L.offBlocks.append(Block(name: name,
                                             rect: NSRect(x: boxInner.minX, y: top, width: boxInner.width, height: h),
                                             fill: color, valueGB: v, kind: .model))
                    top += h + gap
                }
            } else {
                // 宽版：与池子同一 GB 比例（可跨图比较），自下而上、底对齐
                let headerH: CGFloat = 28
                let boxInner = NSRect(x: L.box.minX + 7, y: L.box.minY + headerH,
                                      width: L.box.width - 14,
                                      height: max(10, L.box.height - headerH - 6))
                let pxBox = min(px, boxInner.height / max(0.001, L.offTotal))
                var bottom = boxInner.maxY
                for (name, v, color) in offs {
                    let h = max(2, CGFloat(v) * pxBox)
                    let top = max(boxInner.minY, bottom - h)
                    L.offBlocks.append(Block(name: name,
                                             rect: NSRect(x: boxInner.minX, y: top,
                                                          width: boxInner.width, height: max(0.5, bottom - top)),
                                             fill: color, valueGB: v, kind: .model))
                    bottom = top - gap
                }
            }
        }
        return L
    }

    // ---------- 绘制 ----------

    override func draw(_ dirtyRect: NSRect) {
        guard totalGiB > 0 else { return }
        let L = computeLayout(size: bounds.size)
        let sums = layers()

        // 1) 敞口水箱的「水体」底色（用卡片色：模型列高低不齐时，上方空处不该看着像「别的内存」）
        DS.cardBG.setFill()
        Self.vesselPath(L.tank, radius: 10, closed: true).fill()

        // 2) 色块
        for b in L.blocks { drawBlock(b) }

        // 3) 浮出池口的部分：红色警告（名字与总量写在口沿上方的气泡里，避免红字压红块）
        for o in L.overflows {
            let rad = min(radius, max(0.5, o.rect.height / 2))
            cOverflow.setFill()
            NSBezierPath(roundedRect: o.rect, xRadius: rad, yRadius: rad).fill()
        }
        if L.overflowGB > 0.05 {
            let names = L.overflows.map { $0.name }.joined(separator: " · ")
            var text = String(format: "溢出 %.1f GB", L.overflowGB)
            if !names.isEmpty { text += "（\(names)）" }
            let font = DS.text(9, .semibold)
            let maxW = L.tank.width - 6
            let textW = min(maxW - 14, (text as NSString).size(withAttributes: [.font: font]).width + 14)
            let pill = NSRect(x: L.inner.minX + 2, y: inset + 1, width: max(60, textW), height: 15)
            let pp = NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5)
            DS.cardBG.setFill()
            pp.fill()
            cOverflow.setStroke()
            pp.lineWidth = 1
            pp.stroke()
            drawLeft(text, x: pill.minX + 7, y: pill.minY + 2.5,
                     color: cOverflow, size: 9, bold: true, width: pill.width - 14)
        }

        // 4) 池壁（顶部开口：只有左右壁与池底），最后描
        cWall.setStroke()
        let wall = Self.vesselPath(L.tank, radius: 10, closed: false)
        wall.lineWidth = 1.5
        wall.stroke()

        // 5) 刻度（口沿＝容量）——紧贴池子左壁，与池外小箱分开
        for frac in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let v = totalGiB * frac
            let yy = L.inner.maxY - CGFloat(frac) * L.inner.height
            drawRight(fmt(v), x: L.tank.minX - tickW, y: yy - 6, width: tickW - 4,
                      color: NSColor(calibratedWhite: 0.45, alpha: 1), size: 9, bold: frac == 1.0)
        }

        if isStacked {
            drawLegendCompact(in: L.legend, sums: sums)
        } else {
            drawLegend(in: L.legend, sums: sums)
        }

        // 6) 池外小箱
        drawOffBox(L)
    }

    private func drawBlock(_ b: Block, allowLabel: Bool = true) {
        let rad = min(radius, max(0.5, min(b.rect.height, b.rect.width) / 2))
        let p = NSBezierPath(roundedRect: b.rect, xRadius: rad, yRadius: rad)
        b.fill.setFill()
        p.fill()
        if b.kind == .free {
            NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.27, alpha: 0.85).setStroke()
            p.lineWidth = 0.8
            p.stroke()
        }
        guard allowLabel, b.rect.height >= labelMinHeight else { return }
        drawLabel(b.name, in: b.rect, color: Self.blockInk(on: b.fill))
    }

    private func drawOffBox(_ L: Layout) {
        let box = L.box
        let p = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        DS.cardBG.setFill()
        p.fill()
        DS.cardBorder.setStroke()
        p.lineWidth = 1
        p.stroke()

        if isStacked {
            // 窄版：矮箱、箱内不写模型名（名字靠池内块与颜色关联）
            drawLeft(String(format: "池外 · 未载入 %.1f GB", L.offTotal),
                     x: box.minX + 8, y: box.minY + 1,
                     color: DS.inkSecondary, size: 9, bold: true, width: box.width - 16)
            if L.offBlocks.isEmpty {
                drawLeft("已全部驻留", x: box.minX + 8, y: box.midY - 5,
                         color: DS.inkTertiary, size: 9, bold: false, width: box.width - 16)
            } else {
                for b in L.offBlocks { drawBlock(b, allowLabel: false) }
            }
            return
        }

        // 宽版：瘦小箱（64 pt 宽）——两行短标签，量过宽度，不会溢到刻度列
        drawLeft("池外", x: box.minX + 4, y: box.minY + 5,
                 color: DS.inkSecondary, size: 9.5, bold: true, width: box.width - 8)
        drawLeft("未载", x: box.minX + 4, y: box.minY + 18,
                 color: DS.inkTertiary, size: 8, bold: false, width: box.width - 8)
        drawLeft(String(format: "%.0fGB", L.offTotal), x: box.minX + 4, y: box.minY + 28,
                 color: DS.inkTertiary, size: 8, bold: false, width: box.width - 8)
        if L.offBlocks.isEmpty {
            drawLeft("全部驻留", x: box.minX + 7, y: box.midY,
                     color: DS.inkTertiary, size: 8.5, bold: false, width: box.width - 14)
        } else {
            for b in L.offBlocks { drawWrappedBlock(b) }
        }
    }

    /// 瘦高小箱里的块：名字按英文分行惯例折行（空格 / 连字符处断），块内裁剪
    private func drawWrappedBlock(_ b: Block) {
        let rad = min(radius, max(0.5, min(b.rect.height, b.rect.width) / 2))
        let path = NSBezierPath(roundedRect: b.rect, xRadius: rad, yRadius: rad)
        b.fill.setFill()
        path.fill()
        guard b.rect.height >= labelMinHeight else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.hyphenationFactor = 1.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: DS.text(9.5, .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let inner = b.rect.insetBy(dx: 4, dy: 4)
        let measured = (b.name as NSString).boundingRect(
            with: NSSize(width: inner.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attrs)
        let h = min(measured.height, inner.height)
        let rect = NSRect(x: inner.minX, y: b.rect.midY - h / 2, width: inner.width, height: h)
        (b.name as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLegendCompact(in r: NSRect, sums: LayerSums) {
        // 窄版：只留「一句总量 + 一行色块」，模型名交给池内块（够高时）与颜色对应
        let summary = String(format: "物理 %.0f GB · 已用 %.1f · 空闲 %.1f", totalGiB, usedGiB, sums.free)
        drawLeft(summary, x: r.minX, y: r.minY, color: NSColor(calibratedWhite: 0.15, alpha: 1),
                 size: 10.5, bold: true, width: r.width)
        let font = DS.text(9.5)
        var x = r.minX
        let y = r.minY + 19
        let items: [(String, NSColor, Double)] = [
            ("空闲", cFree, sums.free), ("内核", cKernel, sums.system),
            ("应用", cApp, sums.other), ("压缩", cCompress, sums.compressed),
            ("预留", cReserve, reserveGiB),
        ]
        var rowY = y
        for (name, color, v) in items {
            if v < 0.05 && name != "空闲" { continue }
            let text = "\(name) \(num(v))"
            let tw = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let chipW = 13 + tw + 6
            if x + chipW > r.maxX {
                x = r.minX
                rowY += 15
                if rowY + 12 > r.maxY { break }
            }
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rowY + 3.5, width: 9, height: 9),
                         xRadius: 2, yRadius: 2).fill()
            drawLeft(text, x: x + 13, y: rowY, color: NSColor(calibratedWhite: 0.30, alpha: 1),
                     size: 9.5, bold: false, width: tw + 2)
            x += chipW + 8
        }
    }

    private func num(_ gb: Double) -> String {
        gb >= 10 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    private func drawLegend(in r: NSRect, sums: LayerSums) {
        var yTop = r.minY
        func line(_ text: String, _ color: NSColor, bold: Bool = false, swatch: Bool = false) {
            if swatch {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: yTop + 4, width: 9, height: 9),
                             xRadius: 2, yRadius: 2).fill()
            }
            drawLeft(text, x: r.minX + (swatch ? 14 : 0), y: yTop,
                     color: bold ? NSColor(calibratedWhite: 0.15, alpha: 1)
                                 : NSColor(calibratedWhite: 0.30, alpha: 1),
                     size: bold ? 11 : 10, bold: bold, width: r.width - (swatch ? 14 : 0))
            yTop += bold ? 18 : 15
        }
        line("物理内存 \(fmt(totalGiB))", NSColor(calibratedWhite: 0.15, alpha: 1), bold: true)
        line(String(format: "已用 %.1f · 空闲 %.1f", usedGiB, sums.free), NSColor(calibratedWhite: 0.35, alpha: 1))
        yTop += 5

        // 自上而下＝池内自上而下：空闲 → 模型 → 沉底层
        line("空闲 \(fmt(sums.free))", cFree, swatch: true)
        // 未载入量只在池外小箱里说一次；名称过长自动折行（用户 2026-11-03：这是通用规则）
        for s in slots.prefix(4) {
            let text = String(format: "%.1f GB　%@", s.residentGiB, s.name)
            s.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: yTop + 4, width: 9, height: 9),
                         xRadius: 2, yRadius: 2).fill()
            let textW = r.width - 14
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            para.hyphenationFactor = 1.0
            let attrs: [NSAttributedString.Key: Any] = [
                .font: DS.text(10),
                .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1),
                .paragraphStyle: para,
            ]
            let rr = (text as NSString).boundingRect(
                with: NSSize(width: max(20, textW), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: attrs)
            (text as NSString).draw(with: NSRect(x: r.minX + 14, y: yTop, width: textW,
                                                 height: ceil(rr.height)),
                                    options: [.usesLineFragmentOrigin], attributes: attrs)
            yTop += legendTextHeight(text, width: textW, size: 10, bold: false)
        }
        line("应用与其他 \(fmt(sums.other))", cApp, swatch: true)
        line("系统内核 \(fmt(sums.system))", cKernel, swatch: true)
        line("压缩 \(fmt(sums.compressed))", cCompress, swatch: true)
        line("预留（不可用）\(fmt(reserveGiB))", cReserve, swatch: true)
        if swapGiB > 0.05 {
            yTop += 2
            // 不给色块：红是「溢出警告」的专用色，swap 只是池外的另一本账
            line("已换出到 swap \(fmt(swapGiB))（池外，不画进池内）", NSColor(calibratedWhite: 0.45, alpha: 1))
        }
    }

    // ---------- 敞口水箱轮廓 ----------

    /// 只画左右壁与池底（顶部开口）；closed=true 时闭合上沿用于填底色（不描）。
    private static func vesselPath(_ r: NSRect, radius: CGFloat, closed: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let rad = min(radius, min(r.width, r.height) / 2)
        p.move(to: NSPoint(x: r.minX, y: r.minY))                       // 口沿左
        p.line(to: NSPoint(x: r.minX, y: r.maxY - rad))
        p.curve(to: NSPoint(x: r.minX + rad, y: r.maxY),
                controlPoint1: NSPoint(x: r.minX, y: r.maxY - rad * 0.45),
                controlPoint2: NSPoint(x: r.minX + rad * 0.45, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX - rad, y: r.maxY))                 // 池底
        p.curve(to: NSPoint(x: r.maxX, y: r.maxY - rad),
                controlPoint1: NSPoint(x: r.maxX - rad * 0.45, y: r.maxY),
                controlPoint2: NSPoint(x: r.maxX, y: r.maxY - rad * 0.45))
        p.line(to: NSPoint(x: r.maxX, y: r.minY))                       // 口沿右
        if closed { p.close() }
        return p
    }

    // ---------- 验收：几何文本导出（不靠看图估） ----------

    /// 与 draw 共用 computeLayout ⇒ 导出的矩形就是画出来的矩形。
    func debugDump() -> [String] {
        let L = computeLayout(size: bounds.size)
        var out: [String] = []
        out.append(String(format: "mode=%@  bounds=%.0fx%.0f  viewH=%.1f  tank=%.1f  inner=%.1f  labelMinH=%.1f  overflow=%.2f GB",
                          isStacked ? "narrow" : "wide", bounds.width, bounds.height, viewHeight,
                          L.tank.height, L.inner.height, L.labelMinHeight, L.overflowGB))
        out.append(String(format: "legend  y=%.1f h=%.1f | box y=%.1f h=%.1f",
                          L.legend.minY, L.legend.height, L.box.minY, L.box.height))
        for b in L.blocks {
            let named = b.rect.height >= L.labelMinHeight ? "label" : "—"
            out.append(String(format: "pool  %@  y=%6.1f h=%6.1f x=%6.1f w=%6.1f  %.1f GB  %@",
                              named, b.rect.minY, b.rect.height, b.rect.minX, b.rect.width, b.valueGB, b.name))
        }
        for o in L.overflows {
            out.append(String(format: "over  y=%6.1f h=%6.1f x=%6.1f w=%6.1f  %@",
                              o.rect.minY, o.rect.height, o.rect.minX, o.rect.width, o.name))
        }
        for b in L.offBlocks {
            let named = (!isStacked && b.rect.height >= L.labelMinHeight) ? "label" : "—"
            out.append(String(format: "box   %@  y=%6.1f h=%6.1f  %.1f GB  %@",
                              named, b.rect.minY, b.rect.height, b.valueGB, b.name))
        }
        out.append(String(format: "off   total=%.1f GB  blocks=%d", L.offTotal, L.offBlocks.count))
        return out
    }

    // ---------- 小工具 ----------

    private func fmt(_ gb: Double) -> String {
        gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// 池内块一律白字（2026-11-03 用户令）。**不加描边、不加阴影**：
    /// 用户实测黑阴影反而糊字，干净的白字更好读。
    private static func blockInk(on fill: NSColor) -> NSColor { NSColor.white }

    /// 块内名字：装得下就按英文分行惯例折行，装不下就退回单行省略号
    /// （用户 2026-11-03：折行是通用规则，不是针对某个模型名）
    private func drawLabel(_ s: String, in r: NSRect, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.hyphenationFactor = 1.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: DS.text(9.5, .semibold),
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let inner = NSRect(x: r.minX + 4, y: r.minY, width: max(4, r.width - 8), height: r.height)
        let measured = (s as NSString).boundingRect(
            with: NSSize(width: inner.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attrs)
        if measured.height <= r.height - 4 {
            let h = ceil(measured.height)
            let rect = NSRect(x: inner.minX, y: r.midY - h / 2, width: inner.width, height: h)
            (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
        } else {
            let single = NSMutableParagraphStyle()
            single.alignment = .center
            single.lineBreakMode = .byTruncatingTail
            var a = attrs
            a[.paragraphStyle] = single
            let h = labelMinHeight
            let rect = NSRect(x: inner.minX, y: r.midY - h / 2 + 0.5, width: inner.width, height: h)
            (s as NSString).draw(in: rect, withAttributes: a)
        }
    }

    private func drawCentered(_ s: String, in r: NSRect, color: NSColor, size: CGFloat, bold: Bool) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? DS.text(size, .semibold) : DS.text(size),
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let h = labelMinHeight
        let textRect = NSRect(x: r.minX + 3, y: r.midY - h / 2 + 0.5,
                              width: max(1, r.width - 6), height: h)
        (s as NSString).draw(in: textRect, withAttributes: attrs)
    }

    private func drawLeft(_ s: String, x: CGFloat, y: CGFloat, color: NSColor,
                          size: CGFloat, bold: Bool, width: CGFloat,
                          align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? DS.text(size, .semibold) : DS.text(size),
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size + 4), withAttributes: attrs)
    }

    private func drawRight(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat,
                           color: NSColor, size: CGFloat, bold: Bool) {
        drawLeft(s, x: x, y: y, color: color, size: size, bold: bold, width: width, align: .right)
    }
}
