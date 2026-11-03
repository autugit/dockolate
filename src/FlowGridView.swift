// ============================================================
// 自适应砖石网格（masonry）
// ============================================================
//
// 2026-11-02 用户裁定（DESIGN.md §3.3）：
//   · **所有方块宽度一致，只改高度** —— 高度编码模型大小（凹函数，同内存池段长）
//   · 容器宽度变化时按 minItemWidth 决定列数；最窄一列，其它情况一列塞多块
//   · 长名字靠换行解决，不靠把方块加宽
//
// 版式：按「当前最矮的那一列」落块（greedy masonry），列内自上而下顺序入列。
//   · 不用行优先：等宽 + 变高时行优先会在每行留一大片空白，看起来像丢块
//   · 不用严格等高的行：会把矮块撑高，等于取消了「高度=大小」的编码

import AppKit

final class FlowGridView: NSView {

    /// 单块最小宽度：低于它少一列（容器 740 → 236*3 + 10*2 = 728 放得下三列）
    var minItemWidth: CGFloat = 236
    var spacing: CGFloat = 10

    private var items: [NSView] = []
    private var itemHeights: [CGFloat] = []
    private var heightConstraint: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let c = heightAnchor.constraint(equalToConstant: 0)
        c.isActive = true
        heightConstraint = c
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 每个方块自带高度（等宽由网格统一算）
    func setItems(_ views: [NSView], heights: [CGFloat]) {
        for v in items { v.removeFromSuperview() }
        items = views
        itemHeights = heights
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        needsLayout = true
    }

    /// 当前列数（外部按列数调高度或做单测时用）
    func columns(for width: CGFloat) -> Int {
        guard width > 1 else { return 1 }
        return max(1, Int((width + spacing) / (minItemWidth + spacing)))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 1, !items.isEmpty else {
            if heightConstraint?.constant != 0 { heightConstraint?.constant = 0 }
            return
        }
        let cols = columns(for: width)
        let itemW = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)

        // 每列当前底部（flipped：y 向下增长）
        var bottoms = [CGFloat](repeating: 0, count: cols)
        for (i, v) in items.enumerated() {
            let h = i < itemHeights.count ? max(1, itemHeights[i]) : 132
            // 落进最矮的那列；等高时取最左，保证首块一定在左上
            var target = 0
            for c in 1..<cols where bottoms[c] < bottoms[target] - 0.5 { target = c }
            let y = bottoms[target]
            v.frame = NSRect(x: CGFloat(target) * (itemW + spacing),
                             y: y, width: itemW, height: h)
            bottoms[target] = y + h + spacing
        }
        let h = max(0, (bottoms.max() ?? 0) - spacing)
        if abs((heightConstraint?.constant ?? -1) - h) > 0.5 {
            heightConstraint?.constant = h
        }
    }
}
