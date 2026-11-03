// ============================================================
// 卡片式界面的设计 token 与基础组件（v1.6「卡片 + 双页」）
// ============================================================
//
// 设计权威见 docs/DESIGN.md（从本仓既有实现反推，不是另起一套）：
//   · 颜色语义沿用 main.swift 的 levelColor / ModelState.color
//   · 字阶沿用窗口原有读数：30/15/13/12.5/11/10.5
//   · 圆角：图标格 19、卡片 12、徽标 = 高度一半
//
// 为什么不用 NSTableView：本机没有屏幕录制权限，界面验收靠进程内 cacheDisplay，
// 手工搭的视图树更容易稳定截图；卡片页面本身是「一列卡片」，用 NSStackView + NSScrollView
// 就够，不必引入数据源协议。

import Cocoa

// ============================================================
// MARK: - 设计 token
// ============================================================

enum DS {
    // ---- 表面 ----
    static let pageBG      = NSColor(calibratedWhite: 0.945, alpha: 1)   // 页面底色
    static let cardBG      = NSColor(calibratedWhite: 0.995, alpha: 1)   // 卡片
    static let cardBorder  = NSColor(calibratedWhite: 0.865, alpha: 1)
    static let trackBG     = NSColor(calibratedWhite: 0.90, alpha: 1)    // 水位槽底
    static let hairline    = NSColor(calibratedWhite: 0.90, alpha: 1)

    // ---- 文字 ----
    static let ink         = NSColor(calibratedWhite: 0.10, alpha: 1)
    static let inkSecondary = NSColor(calibratedWhite: 0.38, alpha: 1)
    static let inkTertiary = NSColor(calibratedWhite: 0.55, alpha: 1)

    // ---- 语义色（与图标同源）----
    static let blue   = NSColor(calibratedRed: 0.32, green: 0.62, blue: 0.98, alpha: 1)
    static let green  = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)
    static let amber  = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1)
    static let red    = NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.28, alpha: 1)
    static let purple = NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.88, alpha: 1)

    /// 深一档的语义色：浅底上做文字/描边时用（纯绿 0.30/0.80/0.42 当正文对比度不够）
    static func ink(_ c: NSColor) -> NSColor {
        c.blended(withFraction: 0.28, of: .black) ?? c
    }

    // ---- 字阶 ----
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    static func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static let bigStat   = mono(30, .semibold)
    static let summary   = mono(15, .semibold)
    static let body      = text(13)
    static let row       = text(12.5)
    static let rowMono   = mono(12.5, .semibold)
    static let section   = text(11, .semibold)
    static let caption   = text(10.5)
    static let captionMono = mono(10.5)

    // ---- 间距 / 圆角 ----
    static let pageInset: CGFloat = 20
    static let cardInset: CGFloat = 16
    static let cardGap: CGFloat = 14
    static let stackGap: CGFloat = 8
    static let rowGap: CGFloat = 6
    static let cardRadius: CGFloat = 12
}

// ============================================================
// MARK: - 小工具
// ============================================================

func dkLabel(_ s: String, font: NSFont, color: NSColor = DS.ink,
             align: NSTextAlignment = .left, wrap: Bool = false) -> NSTextField {
    let t = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
    t.font = font
    t.textColor = color
    t.alignment = align
    t.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
    t.translatesAutoresizingMaskIntoConstraints = false
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return t
}

/// 弹性占位：把同一行里的元素推到两端
func dkSpacer(minWidth: CGFloat = 8) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    v.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
    return v
}

func dkHStack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = align
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

func dkVStack(_ views: [NSView], spacing: CGFloat = DS.stackGap, align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = align
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

/// 细分割线（卡片内部）
func dkHairline() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.wantsLayer = true
    v.layer?.backgroundColor = DS.hairline.cgColor
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
}

// ============================================================
// MARK: - 卡片
// ============================================================

final class CardView: NSView {
    let headerRow: NSStackView
    let body: NSStackView
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField

    init(title: String, subtitle: String? = nil) {
        titleLabel = dkLabel(title, font: DS.text(13, .semibold), color: DS.ink)
        subtitleLabel = dkLabel(subtitle ?? "", font: DS.caption, color: DS.inkTertiary)
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        headerRow = dkHStack([titleLabel, dkSpacer(), subtitleLabel], spacing: 10)
        body = dkVStack([], spacing: DS.stackGap)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.cardRadius
        layer?.backgroundColor = DS.cardBG.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DS.cardBorder.cgColor

        let content = dkVStack([headerRow, body], spacing: 10)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: DS.cardInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.cardInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.cardInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.cardInset),
        ])
        // 卡片宽度跟随页面：header 与 body 都要撑满
        body.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        headerRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSubtitle(_ s: String) {
        subtitleLabel.stringValue = s
        subtitleLabel.isHidden = s.isEmpty
    }

    func addRow(_ v: NSView) {
        body.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    func addFullWidth(_ v: NSView) {
        addRow(v)
    }
}

// ============================================================
// MARK: - 徽标（状态药丸）
// ============================================================

final class Pill: NSView {
    private let label: NSTextField
    private(set) var color: NSColor = DS.inkSecondary

    init(_ text: String = "", color: NSColor = DS.inkSecondary) {
        label = dkLabel(text, font: DS.text(10.5, .medium), color: DS.ink(color))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 19),
        ])
        label.alignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.init(999), for: .horizontal)
        setContentCompressionResistancePriority(.init(999), for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ text: String, color: NSColor) {
        self.color = color
        label.stringValue = text
        label.textColor = DS.ink(color)
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
    }
}

// ============================================================
// MARK: - 水位条（单段）
// ============================================================

final class WaterBar: NSView {
    var pct: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = DS.green { didSet { needsDisplay = true } }
    var height: CGFloat = 6

    init(height: CGFloat = 6) {
        self.height = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 0)
        let radius = r.height / 2
        DS.trackBG.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        let f = CGFloat(min(100, max(0, pct)) / 100)
        guard f > 0.004 else { return }
        let fillRect = NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * f), height: r.height)
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

// ============================================================
// MARK: - 内存去向条（多段堆叠）
// ============================================================

final class StackedBar: NSView {
    struct Segment { var value: Double; var color: NSColor; var label: String }
    var segments: [Segment] = [] { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 12).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let total = segments.reduce(0) { $0 + max(0, $1.value) }
        let radius: CGFloat = 4
        DS.trackBG.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard total > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        var x = bounds.minX
        for s in segments where s.value > 0 {
            let w = bounds.width * CGFloat(s.value / total)
            s.color.withAlphaComponent(0.92).setFill()
            NSBezierPath(rect: NSRect(x: x, y: bounds.minY, width: w, height: bounds.height)).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// ============================================================
// MARK: - 指标小格（首页顶部的三个大数字）
// ============================================================

final class StatTile: NSView {
    private let captionLabel: NSTextField
    private let valueLabel: NSTextField
    private let detailLabel: NSTextField
    private let bar = WaterBar(height: 6)

    var color: NSColor = DS.green { didSet { bar.color = color; valueLabel.textColor = DS.ink(color) } }

    init(caption: String) {
        captionLabel = dkLabel(caption, font: DS.section, color: DS.inkTertiary)
        valueLabel = dkLabel("—", font: DS.bigStat, color: DS.ink)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel = dkLabel("", font: DS.caption, color: DS.inkSecondary)
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(calibratedWhite: 0.975, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DS.cardBorder.cgColor

        let stack = dkVStack([captionLabel, valueLabel, bar, detailLabel], spacing: 6)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(value: String, detail: String, pct: Double, color: NSColor) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        bar.pct = pct
        self.color = color
    }
}

// ============================================================
// MARK: - 页面（可滚动）
// ============================================================

/// 翻转坐标系的内容视图：滚动时内容从顶部开始排
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PageView: NSView {
    let scroll = NSScrollView()
    private let doc = FlippedView()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: DS.pageInset),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -DS.pageInset),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: DS.pageInset),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -DS.pageInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func addCard(_ c: NSView) {
        stack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func removeAllCards() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
    }
}
