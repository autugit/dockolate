// ============================================================
// 主窗口（v1.6）：卡片式双页 —— 首页 / AI 管理
// ============================================================
//
// 首页 = 原来的「进程排行窗口」那套内容，改成卡片：
//   系统总览（C/G/M 三格）→ 内存去向 → 本机 AI 模型 → 三榜进程
//
// AI 管理 = 新增页：
//   ① 模型运行时：内存里每个模型这一趟跑了多久、平均 prefill / decode、请求与 token 量（可展开）
//   ② 模型管理器：扫盘出来的全部权重，按类别分组，三色标出「当前可用内存还拉得起吗」，
//      可从这里拉起 / 卸载（没有启动配方的会明说，不假装能点）
//   ③ 工作组：几个模型绑成一个名字一起拉起 / 一起停，合计内存同样三色判定
//
// 布局全部走 NSStackView + Auto Layout（不再手工摆 frame）：卡片页天然是一列，
// 滚动视图负责长内容；验收靠进程内 cacheDisplay（本机无屏幕录制权限）。

import Cocoa

// ============================================================
// MARK: - 小行视图
// ============================================================

/// 首页：进程榜的一行
final class ProcLineView: NSView {
    private let nameLabel = dkLabel("—", font: DS.row, color: DS.ink)
    private let valueLabel = dkLabel("", font: DS.rowMono, color: DS.ink, align: .right)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = dkHStack([nameLabel, dkSpacer(), valueLabel], spacing: 8)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(name: String, value: String, color: NSColor?) {
        nameLabel.stringValue = name
        valueLabel.stringValue = value
        valueLabel.textColor = color ?? DS.ink
    }
}

/// 首页 / 运行时：模型一行（名称 · 状态 · 内存）
final class ModelLineView: NSView {
    private let nameLabel = dkLabel("—", font: DS.row, color: DS.ink)
    private let pill = Pill("—")
    private let memLabel = dkLabel("", font: DS.rowMono, color: DS.ink, align: .right)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = dkHStack([nameLabel, dkSpacer(), pill, memLabel], spacing: 8)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        memLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(name: String, state: ModelState, mem: Double) {
        nameLabel.stringValue = name
        pill.update(state.text, color: state.color)
        memLabel.stringValue = mem > 0.01 ? String(format: "%.2f GB", mem) : "—"
    }
}

// ============================================================
// MARK: - 运行时（每个在内存里的模型一行，可展开细节）
// ============================================================

final class RuntimeRowView: NSView {
    let entryID: String
    private let disclosure = NSButton(title: "▸", target: nil, action: nil)
    private let nameLabel = dkLabel("", font: DS.text(13, .semibold), color: DS.ink)
    private let engineLabel = dkLabel("", font: DS.caption, color: DS.inkTertiary)
    private let pill = Pill("—")
    private let memLabel = dkLabel("", font: DS.rowMono, color: DS.ink, align: .right)
    /// 「模型运行时」里的直接卸载按钮：内存里在跑的模型不必再回下面的模型管理器去找。
    private let stopButton = NSButton(title: "卸载", target: nil, action: nil)
    /// 指标行：窄窗口时允许折成两行，别把「输入/输出 token」截成省略号（用户 2026-11-03 报）
    private let metricLine = dkLabel("", font: DS.captionMono, color: DS.inkSecondary, wrap: true)
    private let detailStack: NSStackView
    private let detailLabels: [NSTextField]
    private var expanded = false
    var onToggle: (() -> Void)?
    var onStop: (() -> Void)?

    init(id: String) {
        entryID = id
        detailLabels = (0..<3).map { _ in dkLabel("", font: DS.captionMono, color: DS.inkTertiary) }
        detailStack = dkVStack(detailLabels, spacing: 3)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        disclosure.isBordered = false
        disclosure.font = DS.text(11, .semibold)
        disclosure.contentTintColor = DS.inkSecondary
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.setButtonType(.momentaryPushIn)
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = DS.text(11)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        stopButton.contentTintColor = DS.ink(DS.red)

        memLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true
        metricLine.maximumNumberOfLines = 2
        nameLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)

        let top = dkHStack([disclosure, nameLabel, engineLabel, dkSpacer(), pill, memLabel, stopButton], spacing: 8)
        let root = dkVStack([top, metricLine, detailStack], spacing: 4)
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: root.widthAnchor),
            metricLine.widthAnchor.constraint(equalTo: root.widthAnchor),
            detailStack.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        detailStack.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        expanded.toggle()
        detailStack.isHidden = !expanded
        disclosure.title = expanded ? "▾" : "▸"
        onToggle?()
    }

    @objc private func stopTapped() { onStop?() }

    func setExpanded(_ on: Bool) {
        expanded = on
        detailStack.isHidden = !on
        disclosure.title = on ? "▾" : "▸"
    }

    func update(name: String, engine: String, state: ModelState, memGB: Double,
                metric: RuntimeMetric?, action: ModelActionRunner.State?,
                canStop: Bool = true, busy: Bool = false, blockedReason: String? = nil) {
        nameLabel.stringValue = name
        engineLabel.stringValue = engine.isEmpty ? "" : "· " + engine
        pill.update(state.text, color: state.color)
        memLabel.stringValue = memGB > 0.01 ? String(format: "%.2f GB", memGB) : "—"

        // 卸载按钮：内存里在跑就能点（与模型管理器的 canStop 同一判据），停止过程中显示进度并禁用
        let stopping = isStopping(action)
        stopButton.isEnabled = canStop && !busy
        stopButton.title = stopping ? "停止中…" : "卸载"
        stopButton.toolTip = canStop
            ? "卸载 / 停止「\(name)」——与模型管理器里的卸载等价"
            : (blockedReason ?? "这个运行中的模型没有可用的停止方式")

        var bits: [String] = []
        if let m = metric {
            if let up = m.uptime { bits.append("运行 " + prettyUptime(up)) }
            if let md = m.media {
                // 生图 / 视频：轮次 · 每轮耗时 · 当前这轮的已用时间
                bits.append(contentsOf: mediaSummaryLine(md))
            } else {
                bits.append("prefill " + (m.prefillTokS.map { String(format: "%.0f tok/s", $0) } ?? "—"))
                bits.append("decode " + (m.decodeTokS.map { String(format: "%.1f tok/s", $0) } ?? "—"))
                if m.requests > 0 { bits.append("\(m.requests) 次请求") }
                if m.tokensIn > 0 || m.tokensOut > 0 {
                    bits.append("输入 \(compactCount(m.tokensIn)) / 输出 \(compactCount(m.tokensOut))")
                }
            }
        } else {
            bits.append("指标来源未配置（只显示运行时间）")
        }
        if let a = action, a.phase.isBusy || !a.detail.isEmpty || isFailed(a.phase) {
            bits.append(actionText(a))
        }
        metricLine.stringValue = bits.joined(separator: " · ")

        // 展开区：来源 / 端口与 pid / 备注
        var d: [String] = []
        if let m = metric, let md = m.media {
            // 生图 / 视频：当前这轮 · 每轮耗时与上一条规格 · 数据来源（三项由 mediaDetailLines 给）
            d.append(contentsOf: mediaDetailLines(md))
        } else if let m = metric {
            d.append("平均 TTFT：" + (m.ttftAvgS.map { String(format: "%.2f s", $0) } ?? "—")
                     + "　｜　数据来源：" + (m.source.isEmpty ? "未配置" : m.source))
            if let last = m.lastRequestAt {
                d.append("最近一次请求：" + timeString(last) + (m.note.isEmpty ? "" : "　｜　" + m.note))
            } else if !m.note.isEmpty {
                d.append("备注：" + m.note)
            } else {
                d.append("本次加载后还没有请求")
            }
            d.append("说明：平均值从「本次加载」起算；命中前缀缓存的请求不计入 prefill 平均（那部分没重算）")
        } else {
            d.append("未配置日志 / /metrics 指标来源 —— 在 registry.json 的 recipes 里填 log + metrics 即可")
            d.append("生图 / 视频服务填 media（comfyui 或 mlxserve），就会改显示轮次与每轮耗时")
        }
        for (i, l) in detailLabels.enumerated() {
            l.stringValue = i < d.count ? d[i] : ""
            l.isHidden = i >= d.count
        }
    }

    private func isFailed(_ p: ModelActionRunner.Phase) -> Bool {
        if case .failed = p { return true }
        return false
    }

    private func isStopping(_ a: ModelActionRunner.State?) -> Bool {
        guard let a = a else { return false }
        if case .stopping = a.phase { return true }
        return false
    }

    private func actionText(_ a: ModelActionRunner.State) -> String {
        switch a.phase {
        case .launching(let t): return "拉起中 " + prettyUptime(Date().timeIntervalSince(t))
        case .stopping(let t):  return "停止中 " + prettyUptime(Date().timeIntervalSince(t))
        case .failed(let m):    return "失败：" + m
        case .idle:             return a.detail
        }
    }
}

private func compactCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
    return "\(n)"
}

private func timeString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

// ============================================================
// MARK: - 模型管理器的一行
// ============================================================

final class CatalogRowView: NSView {
    let entryID: String
    private let dot = NSView()
    private let titleLabel = dkLabel("", font: DS.text(12.5, .medium), color: DS.ink)
    private let subLabel = dkLabel("", font: DS.caption, color: DS.inkSecondary)
    private let sizeLabel = dkLabel("", font: DS.captionMono, color: DS.inkSecondary, align: .right)
    private let estLabel = dkLabel("", font: DS.captionMono, color: DS.inkSecondary, align: .right)
    private let pill = Pill("—")
    private let launchButton = NSButton(title: "拉起", target: nil, action: nil)
    private let stopButton = NSButton(title: "卸载", target: nil, action: nil)
    private let stateLabel = dkLabel("", font: DS.caption, color: DS.inkTertiary)
    /// 分类小标签：网格不再按分类分段，分类信息落进方块里
    private let categoryLabel = dkLabel("", font: DS.captionMono, color: DS.inkTertiary)
    /// 类型徽标：SF Symbol + 分类配色，一眼区分 推理 / 生图 / 视频 / 语音 / 嵌入 / 服务
    private let categoryBadge: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleProportionallyDown
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 15),
            v.heightAnchor.constraint(equalToConstant: 15),
        ])
        return v
    }()
    /// 大水印：同一枚图标放大到半透明铺在卡片底上（2026-11-04 用户要求），
    /// 远处一眼就能认出这是推理 / 生图 / 视频 / 语音。
    private let watermark: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleProportionallyUpOrDown
        v.isEditable = false
        return v
    }()
    private let policyButton = NSButton(title: "策略", target: nil, action: nil)
    var onLaunch: (() -> Void)?
    var onStop: (() -> Void)?
    var onEditPolicy: (() -> Void)?

    init(id: String) {
        entryID = id
        super.init(frame: .zero)
        // 卡片外观：宽度由网格决定（不再占满整行），内部全部竖直排
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = DS.cardBorder.cgColor
        layer?.backgroundColor = DS.cardBG.cgColor

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        titleLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // 长模型名换行显示（最多两行）——不靠把方块加宽（2026-11-02 用户裁定）
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = false
        titleLabel.cell?.wraps = true
        // wraps + truncatesLastVisibleLine 才会有「第二行末尾省略号」；
        // 只设 wraps 会在词中间硬切（实测长模型名会在连字符处被切掉后半段）。
        titleLabel.cell?.truncatesLastVisibleLine = true
        subLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        subLabel.maximumNumberOfLines = 2
        subLabel.lineBreakMode = .byTruncatingTail
        stateLabel.maximumNumberOfLines = 1
        stateLabel.lineBreakMode = .byTruncatingTail

        for b in [launchButton, stopButton, policyButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = DS.text(11)
            b.translatesAutoresizingMaskIntoConstraints = false
            if b !== policyButton {
                b.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
            }
        }
        policyButton.target = self
        policyButton.action = #selector(policyTapped)
        policyButton.toolTip = "编辑调度策略（写回 registry.json）"
        launchButton.target = self
        launchButton.action = #selector(launchTapped)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)

        sizeLabel.alignment = .left
        estLabel.alignment = .left

        let titleRow = dkHStack([categoryBadge, dot, titleLabel, dkSpacer(), pill], spacing: 6)
        let metaRow = dkHStack([categoryLabel, sizeLabel, estLabel, dkSpacer()], spacing: 8)
        let buttonRow = dkHStack([policyButton, dkSpacer(), launchButton, stopButton], spacing: 6)
        let content = dkVStack([titleRow, subLabel, metaRow, stateLabel], spacing: 4)
        stateLabel.isHidden = true
        addSubview(watermark)        // 先加 = 在最底层，内容压在水印上
        watermark.wantsLayer = true
        NSLayoutConstraint.activate([
            watermark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            watermark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2),
            watermark.widthAnchor.constraint(equalToConstant: 108),
            watermark.heightAnchor.constraint(equalToConstant: 108),
        ])
        addSubview(content)
        addSubview(buttonRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            // 按钮钉在方块底部：方块高度随模型大小变，按钮不能跟着文字浮在半空
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            content.bottomAnchor.constraint(lessThanOrEqualTo: buttonRow.topAnchor, constant: -6),
            titleRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            metaRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func policyTapped() { onEditPolicy?() }
    @objc private func launchTapped() { onLaunch?() }
    @objc private func stopTapped() { onStop?() }

    /// 方块表面色 = 状态色（DESIGN.md §2.3 语义色，2026-11-02 用户裁定）
    ///   运行中/待机 蓝 · 拉起中/停止中 琥珀（更浓） · 可拉起 绿 · 勉强够 黄 · 内存不足 红 · 不可单独起 灰
    private func surfaceTint(entry: CatalogEntry, fit: FitLevel, busy: Bool) -> NSColor {
        if busy { return DS.amber }
        switch entry.state {
        case .running, .idle: return DS.blue
        case .loading:        return DS.amber
        case .failed:         return DS.red
        default:              break
        }
        // 内存不足先判：那是「状态」，不能被「未配置启动方式」的灰盖掉
        if fit == .insufficient { return DS.red }
        if !entry.canLaunch { return DS.inkTertiary }
        return fit.color
    }

    func update(entry: CatalogEntry, fit: FitLevel, action: ModelActionRunner.State?,
                policy: HubPolicyEntry? = nil, metric: RuntimeMetric? = nil,
                compact: Bool = false) {
        titleLabel.stringValue = entry.title
        // 副标题固定结构：
        //   第一行 = 策略摘要（没有策略时退化为目录）
        //   第二行 = 目录末段（路径全量、含哪些部件都进 tooltip）
        var dirLine = entry.subtitle
        if let sep = dirLine.range(of: " · ") {
            let head = String(dirLine[..<sep.lowerBound])
            let path = String(dirLine[sep.upperBound...])
            let tail = (path as NSString).lastPathComponent
            if !tail.isEmpty { dirLine = head + " · " + tail }
        }
        var tip = entry.subtitle
        if !entry.parts.isEmpty && entry.category != .part {
            tip += "\n含 " + entry.parts.joined(separator: "、")
        }
        // 「池内」的卡显示运行指标，「池外」的卡显示目录 —— 同一张卡的两个形态，
        // 不额外增加行数（卡片高度固定，多一行会挤掉按钮）。
        let isLoaded = [ModelState.running, .idle, .loading].contains(entry.state)
        var metricLine: String?
        if isLoaded, let mt = metric {
            var bits: [String] = []
            if let up = mt.uptime { bits.append("已跑 " + prettyUptime(up)) }
            if let md = mt.media {
                // 生图 / 视频：卡片上只留「几张 / 每张多久 / 当前这一张多久」
                bits.append(contentsOf: mediaCompactLine(md))
            } else {
                if let d = mt.decodeTokS { bits.append(String(format: "decode %.0f tok/s", d)) }
                if mt.requests > 0 { bits.append("\(mt.requests) 请求") }
            }
            if !bits.isEmpty { metricLine = bits.joined(separator: " · ") }
        }
        let secondLine = metricLine ?? dirLine
        if let policyLine = HubPolicies.summary(for: entry) {
            subLabel.stringValue = policyLine + "\n" + secondLine
            tip = (HubPolicies.fullSummary(for: entry) ?? "") + "\n" + tip
        } else {
            subLabel.stringValue = secondLine
        }
        if metricLine != nil, let mt = metric {
            var detail: [String] = []
            if let md = mt.media {
                detail.append(contentsOf: mediaDetailLines(md).prefix(2))
            } else {
                if let p = mt.prefillTokS { detail.append(String(format: "prefill %.0f tok/s", p)) }
                if let t2 = mt.ttftAvgS { detail.append(String(format: "TTFT %.2fs", t2)) }
                if mt.tokensOut > 0 {
                    detail.append("输出 \(mt.tokensOut >= 1000 ? "\(mt.tokensOut / 1000)k" : "\(mt.tokensOut)")")
                }
            }
            if !detail.isEmpty { tip += "\n" + detail.joined(separator: " · ") }
            tip += "\n（目录：\(entry.subtitle)）"
        }
        subLabel.toolTip = tip
        // 紧凑方块（小模型）：藏副标题，让方块真的只占一小块
        subLabel.isHidden = compact
        sizeLabel.stringValue = entry.diskGB > 0.01 ? String(format: "盘 %.1f GB", entry.diskGB) : "盘 —"
        estLabel.stringValue = entry.estMemGB > 0.01 ? String(format: "≈%.1f GB", entry.estMemGB) : "—"
        estLabel.toolTip = entry.estBasis
        categoryLabel.stringValue = entry.category.icon + " " + entry.category.title
        // 类型视觉：形状 + 配色都由数据决定（registry.json 的 categoryVisuals 可覆盖）
        let symName = ModelVisuals.symbol(entry.category)
        let accent = ModelVisuals.color(entry.category)
        let sym = NSImage(systemSymbolName: symName, accessibilityDescription: entry.category.title)
        sym?.isTemplate = true
        categoryBadge.image = sym
        categoryBadge.contentTintColor = accent
        categoryBadge.toolTip = entry.category.title
        // 半透明大水印：同一枚图标放大铺在右上，图标色 = 类型色
        let big = NSImage(systemSymbolName: symName, accessibilityDescription: entry.category.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: compact ? 64 : 96, weight: .regular))
        big?.isTemplate = true
        watermark.image = big
        watermark.contentTintColor = accent
        watermark.alphaValue = compact ? 0.10 : 0.13
        let running = [ModelState.running, .idle, .loading].contains(entry.state)
        if running {
            pill.update(entry.state.text, color: entry.state.color)
            dot.layer?.backgroundColor = entry.state.color.cgColor
        } else {
            pill.update(fit.text(canLaunch: entry.canLaunch), color: fit.color)
            dot.layer?.backgroundColor = fit.color.cgColor
        }

        // 方块表面按状态着色（2026-11-02 用户裁定：颜色 = 状态，一眼可辨）
        // 用不透明混色而不是半透明底：卡片底色是近白，9% alpha 的色块在浅底上等于没上色（踩过）。
        let busyNow = action?.phase.isBusy ?? false
        let tint = surfaceTint(entry: entry, fit: fit, busy: busyNow)
        let wash = DS.cardBG.blended(withFraction: busyNow ? 0.22 : 0.14, of: tint) ?? DS.cardBG
        layer?.backgroundColor = wash.cgColor
        layer?.borderColor = tint.withAlphaComponent(busyNow ? 0.75 : 0.45).cgColor
        layer?.borderWidth = busyNow ? 1.5 : 1

        policyButton.isHidden = (policy == nil)
        let busy = action?.phase.isBusy ?? false
        launchButton.isEnabled = entry.canLaunch && !busy
        stopButton.isEnabled = entry.canStop && !busy
        launchButton.toolTip = entry.canLaunch ? "按配方拉起（\(entry.recipe?.start?.display ?? "内置适配器")）"
                                               : (entry.blockedReason ?? "不可拉起")
        stopButton.toolTip = entry.canStop ? "卸载 / 停止" : (entry.blockedReason ?? "不可卸载")

        var note = ""
        if let a = action {
            switch a.phase {
            case .launching(let t): note = "拉起中 " + prettyUptime(Date().timeIntervalSince(t)) + "…" + (a.detail.isEmpty ? "" : "（\(a.detail)）")
            case .stopping(let t):  note = "停止中 " + prettyUptime(Date().timeIntervalSince(t)) + "…"
            case .failed(let m):    note = "✗ " + m + (a.detail.isEmpty ? "" : "　" + a.detail.replacingOccurrences(of: "\n", with: " "))
            case .idle:             note = a.detail
            }
        } else if !entry.canLaunch && entry.state != .running && entry.state != .idle {
            note = entry.blockedReason ?? ""
        }
        // 策略只在副标题第一行显示一次（这里不再重复，否则同一张卡出现两条策略）
        stateLabel.stringValue = note
        stateLabel.isHidden = compact || note.isEmpty
        stateLabel.textColor = {
            if case .failed = action?.phase { return DS.ink(DS.red) }
            return DS.inkTertiary
        }()
    }
}

// ============================================================
// MARK: - 中枢策略缓存（界面展示用）
// ============================================================

enum HubPolicies {
    private(set) static var registry = HubRegistry.load()

    static func refresh() { registry = HubRegistry.load() }

    static func policy(for entry: CatalogEntry) -> HubPolicyEntry? {
        registry.entry(for: entry.id, recipe: entry.recipe?.id)
    }

    /// 「策略：驻留 · 掉线不重拉 · 互斥 X · 不对外」这样的单行摘要
    static func summary(for entry: CatalogEntry) -> String? {
        guard let pol = policy(for: entry) else { return nil }
        // 只列「偏离默认」的项：默认是 不自启 / 掉线不重拉 / 对外。
        // 全列出来会在窄卡片里被省略号吃掉（每一行都是 5-6 个词）。
        var badges: [String] = [pol.resident ? "驻留" : "不驻留"]
        if pol.autoStart { badges.append("自启") }
        if pol.restartOnCrash { badges.append("崩溃重拉") }
        if !pol.mutexWith.isEmpty { badges.append("互斥 " + pol.mutexWith.joined(separator: "/")) }
        if !pol.exposed { badges.append("不对外") }
        if let g = pol.group { badges.append("组 " + g) }
        return badges.joined(separator: " · ")
    }

    /// 完整策略（给 tooltip 用，不省略任何一项）
    static func fullSummary(for entry: CatalogEntry) -> String? {
        guard let pol = policy(for: entry) else { return nil }
        var parts: [String] = [pol.resident ? "驻留内存" : "不驻留"]
        parts.append(pol.autoStart ? "开机自启" : "不自启")
        parts.append(pol.restartOnCrash ? "崩溃自动重拉" : "掉线不重拉")
        if !pol.mutexWith.isEmpty { parts.append("互斥 " + pol.mutexWith.joined(separator: "/")) }
        parts.append(pol.exposed ? "对外可见" : "不对外")
        if let g = pol.group { parts.append("组 " + g) }
        return "策略：" + parts.joined(separator: " · ")
    }
}

// ============================================================
// MARK: - 工作组的一行
// ============================================================

final class WorkgroupRowView: NSView {
    let groupID: String
    private let nameLabel = dkLabel("", font: DS.text(12.5, .semibold), color: DS.ink)
    private let memberLabel = dkLabel("", font: DS.caption, color: DS.inkTertiary)
    private let estLabel = dkLabel("", font: DS.captionMono, color: DS.inkSecondary, align: .right)
    private let pill = Pill("—")
    private let launchButton = NSButton(title: "启动全部", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止全部", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    var onLaunch: (() -> Void)?
    var onStop: (() -> Void)?
    var onDelete: (() -> Void)?

    init(id: String) {
        groupID = id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for b in [launchButton, stopButton, deleteButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = DS.text(11)
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        launchButton.widthAnchor.constraint(equalToConstant: 70).isActive = true
        stopButton.widthAnchor.constraint(equalToConstant: 70).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        deleteButton.contentTintColor = DS.red
        launchButton.target = self; launchButton.action = #selector(launchTapped)
        stopButton.target = self; stopButton.action = #selector(stopTapped)
        deleteButton.target = self; deleteButton.action = #selector(deleteTapped)

        estLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let text = dkVStack([nameLabel, memberLabel], spacing: 1)
        let row = dkHStack([text, dkSpacer(), estLabel, pill, launchButton, stopButton, deleteButton], spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func launchTapped() { onLaunch?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func deleteTapped() { onDelete?() }

    func update(group: Workgroup, members: [CatalogEntry], fit: FitLevel, action: ModelActionRunner.State?) {
        nameLabel.stringValue = group.name
        let names = members.map { $0.title }
        memberLabel.stringValue = names.isEmpty ? "（成员已不在清单里）" : names.joined(separator: " + ")
        let total = members.reduce(0) { $0 + $1.estMemGB }
        // 已经在内存里的成员不该再算进「还要多少内存」——
        // 否则「27B 已在跑 + 再拉一个生图」会被判成放不下（实测被用户抓到）。
        let resident = members.filter { [.running, .idle, .loading].contains($0.state) }
        let needed = total - resident.reduce(0) { $0 + $1.estMemGB }
        if resident.isEmpty {
            estLabel.stringValue = total > 0.01 ? String(format: "≈%.1f GB", total) : "—"
        } else {
            estLabel.stringValue = String(format: "≈%.1f（需再 %.1f）", total, max(0, needed))
        }
        pill.update(fit.text(canLaunch: members.contains { $0.canLaunch }), color: fit.color)
        let busy = action?.phase.isBusy ?? false
        launchButton.isEnabled = !busy && !members.isEmpty
        stopButton.isEnabled = !busy && !members.isEmpty
        if let a = action {
            switch a.phase {
            case .launching(let t): memberLabel.stringValue = "启动中 " + prettyUptime(Date().timeIntervalSince(t)) + "… " + (a.detail)
            case .stopping:         memberLabel.stringValue = "停止中… " + (a.detail)
            case .failed(let m):    memberLabel.stringValue = "✗ " + m + " " + (a.detail)
            case .idle:             if !a.detail.isEmpty { memberLabel.stringValue = a.detail }
            }
        }
    }
}

// ============================================================
// MARK: - 新建工作组（sheet）
// ============================================================

final class WorkgroupSheet: NSObject {
    private var window: NSWindow?
    private var nameField: NSTextField!
    private var checks: [(id: String, box: NSButton)] = []
    private var completion: ((Workgroup?) -> Void)?

    func present(in parent: NSWindow, entries: [CatalogEntry], existing: [Workgroup], done: @escaping (Workgroup?) -> Void) {
        completion = done
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "新建工作组"
        w.appearance = NSAppearance(named: .aqua)
        let content = NSView(frame: w.contentLayoutRect)
        w.contentView = content

        let name = NSTextField(string: "")
        name.placeholderString = "工作组名字（例如：27B + 生图）"
        name.font = DS.text(13)
        name.translatesAutoresizingMaskIntoConstraints = false
        nameField = name

        let hint = dkLabel("勾选要一起拉起的模型。合计内存按各自的估算相加；红色表示当前内存放不下这几个同时驻留。",
                           font: DS.caption, color: DS.inkTertiary, wrap: true)
        hint.preferredMaxLayoutWidth = 460

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false

        for e in entries where e.category != .part {
            let box = NSButton(checkboxWithTitle: e.title + "　≈" + String(format: "%.1f GB", e.estMemGB),
                               target: nil, action: nil)
            box.font = DS.text(12)
            box.translatesAutoresizingMaskIntoConstraints = false
            box.state = .off
            listStack.addArrangedSubview(box)
            checks.append((e.id, box))
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 10),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -10),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        for b in [cancel, save] {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        let buttons = dkHStack([dkSpacer(), cancel, save], spacing: 10)

        for v in [name, hint, scroll, buttons] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            name.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            name.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        _ = existing
        window = w
        parent.beginSheet(w) { _ in }
    }

    @objc private func saveTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let members = checks.filter { $0.box.state == .on }.map { $0.id }
        guard !name.isEmpty, !members.isEmpty else {
            NSSound.beep()
            return
        }
        finish(Workgroup(id: UUID().uuidString, name: name, members: members))
    }

    @objc private func cancelTapped() { finish(nil) }

    private func finish(_ g: Workgroup?) {
        if let w = window { w.sheetParent?.endSheet(w); w.orderOut(nil) }
        window = nil
        completion?(g)
        completion = nil
    }
}

// ============================================================
// MARK: - 主窗口控制器
// ============================================================

final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var segment: NSSegmentedControl!
    private var homePage: PageView!
    private var managerPage: PageView!
    private var headerStatus: NSTextField!

    // ---- 数据 ----
    var sampleProvider: (() -> Sample)?
    private let procSampler = ProcessSampler()
    private let watcher = EngineWatcher()
    private let metricsStore = MetricsStore()
    private let inventory = ModelInventory()
    private let actions = ModelActionRunner()
    private var config = LauncherConfig.load()
    /// 中枢策略（registry.json）：界面展示用，每轮重读保持与中枢一致
    private var hubRegistry = HubRegistry.load()
    private var observed = ObservedMemory()
    private var groups: [Workgroup] = WorkgroupStore.load()

    private var snapshot = ModelSnapshot()
    private var engineBusy = false
    private var engineAt = Date.distantPast
    private var metricsByKey: [String: RuntimeMetric] = [:]

    private var entries: [CatalogEntry] = []
    private var diskUnits: [DiskUnit] = []
    private var scanRoots: [String] = []
    private var catalogBusy = false
    private var catalogAt = Date.distantPast
    private var catalogSeconds: Double = 0
    private var catalogFingerprint = ""

    private var budget = MemoryBudget()
    private var latestSample = Sample()
    private var hubSeq = 0
    private let policySheet = PolicyEditSheet()
    /// 窗口已关闭但进程仍在（后台驻留）
    private var windowIsClosed = false
    private var lastRefreshAt = Date.distantPast
    private var timer: Timer?
    private var expandedRuntime = Set<String>()
    /// 自检截图时冻结后台探测/扫盘：注入的演示数据不会被真实数据在两秒内覆盖
    private var selfCheckFrozen = false

    // ---- 首页视图 ----
    private let cpuTile = StatTile(caption: "CPU 占用")
    private let gpuTile = StatTile(caption: "GPU 占用")
    private let memTile = StatTile(caption: "内存占用")
    private var memBarLabel: NSTextField!
    private var memBar = StackedBar()
    private var memLegend: NSTextField!
    private var memFootnote: NSTextField!
    private var homeModelRows: [ModelLineView] = []
    private var homeModelFoot: NSTextField!
    private var procLines: [[ProcLineView]] = [[], [], []]

    // ---- AI 管理页视图 ----
    private let runtimeCard = CardView(title: "模型运行时", subtitle: "内存里正在跑的模型")
    private var runtimeRows: [String: RuntimeRowView] = [:]
    private var runtimeEmpty: NSTextField!
    private let catalogCard = CardView(title: "模型管理器", subtitle: "")
    private let poolCard = CardView(title: "内存蓄水池", subtitle: "池内＝已驻留与空闲（绿）· 浮出池口＝红 · 右侧小箱＝未载入内存的权重")
    private let poolBar = MemoryReservoirView()
    private var catalogRows: [String: CatalogRowView] = [:]
    /// 每个方块的高度（= 大小编码），刷新时据此决定是否进紧凑态
    private var catalogTileHeights: [String: CGFloat] = [:]
    private var catalogEmpty: NSTextField!
    private var catalogFoot: NSTextField!
    private let catalogList = NSStackView()
    private var catalogHeader: NSTextField!
    // 排序（用户裁定 2026-11-04）：托盘＝调用次数 / 名称；模型＝调用次数 / 名称 / 大小
    private enum TraySort: Int { case usage, name }
    private enum ModelSort: Int { case usage, name, size }
    private var traySort = TraySort(rawValue: UserDefaults.standard.integer(forKey: "dk.sortTrays")) ?? .usage
    private var modelSort = ModelSort(rawValue: UserDefaults.standard.integer(forKey: "dk.sortModels")) ?? .usage
    private var traySortPopup: NSPopUpButton!
    private var modelSortPopup: NSPopUpButton!
    /// 跨重启累计的调用次数（引擎重启后计数归零，这里按增量累加，排序才不会被会话割断）
    private var usageCounts: [String: Int] = (UserDefaults.standard.dictionary(forKey: "dk.usageCounts") as? [String: Int]) ?? [:]
    /// 上一次看到的引擎侧请求数，用来算增量
    private var lastSeenRequests: [String: Int] = [:]
    private let workgroupCard = CardView(title: "工作组", subtitle: "一起拉起 / 一起停")
    private var workgroupRows: [String: WorkgroupRowView] = [:]
    private var workgroupEmpty: NSTextField!
    private let sheet = WorkgroupSheet()

    // ============================================================
    // MARK: 生命周期
    // ============================================================

    func show() {
        if window == nil { build() }
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        start()
    }

    // MARK: - 中枢准入（拉起前的判定交给 --ensure，GUI 不自行判断互斥）

    private struct HubVerdict {
        let allowed: Bool
        let message: String
        let blockers: [String]
    }

    private func runEnsure(_ args: [String], completion: @escaping (HubVerdict) -> Void) {
        guard let exe = Bundle.main.executablePath else {
            completion(HubVerdict(allowed: true, message: "无法定位自身可执行文件，按放行处理", blockers: []))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = proc.terminationStatus
            let msg = (obj?["message"] as? String) ?? ""
            let blockers = (obj?["blockers"] as? [String]) ?? []
            DispatchQueue.main.async {
                completion(HubVerdict(allowed: code == 0, message: msg, blockers: blockers))
            }
        }
        do { try p.run() } catch {
            completion(HubVerdict(allowed: true, message: "准入程序启动失败：\(error.localizedDescription)", blockers: []))
        }
    }

    private func hubAdmit(entry: CatalogEntry, completion: @escaping (Bool) -> Void) {
        guard let pol = HubPolicies.policy(for: entry) else { completion(true); return }  // 没策略：沿用旧行为
        runEnsure(["--ensure=\(pol.id)", "--json"]) { [weak self] verdict in
            guard let self = self else { return }
            if verdict.allowed { completion(true); return }

            let a = NSAlert()
            a.messageText = "中枢拒绝拉起「\(entry.title)」"
            a.informativeText = verdict.message.isEmpty
                ? "已有互斥的模型驻留内存。"
                : verdict.message + "\n\n切换会先停掉正在跑的模型，正在进行的任务会中断。"
            a.addButton(withTitle: "取消")
            a.addButton(withTitle: "切换过去")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertSecondButtonReturn else { completion(false); return }

            // 用户明确选择切换，才走 --switch
            self.runEnsure(["--ensure=\(pol.id)", "--switch", "--json"]) { switched in
                if switched.allowed {
                    completion(true)
                } else {
                    let f = NSAlert()
                    f.messageText = "切换失败"
                    f.informativeText = switched.message.isEmpty ? "中枢未能完成切换。" : switched.message
                    f.addButton(withTitle: "好")
                    f.runModal()
                    completion(false)
                }
            }
        }
    }

    /// 仅自检用：按指定宽度渲染，验收卡片流的换列行为
    func setShotWidth(_ width: CGFloat) {
        window?.setContentSize(NSSize(width: width, height: 900))
        window?.layoutIfNeeded()
    }

    func show(page: Int) {
        show()
        segment.selectedSegment = page
        switchPage(page)
    }

    private func start() {
        guard timer == nil else { return }
        _ = procSampler.topGPU()               // 建基准
        actions.onChange = { [weak self] in
            guard let self = self else { return }
            self.engineAt = .distantPast       // 动作结束后尽快重新探测
            self.refresh()
        }
        // 3 秒足够：界面上的数字不需要 2 秒级更新，而每次刷新要探测引擎 + 重排卡片
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗口不等于退出（用户 2026-10-29 要求：默认后台驻留，只有右键「退出」才结束）。
        // 刷新循环继续跑：中枢状态要继续写、引擎状态要继续采，否则关掉界面就等于把中枢也关了。
        // 开销是 2 秒一次的本机探测，可以忽略。
        windowIsClosed = true
    }

    // ============================================================
    // MARK: 搭界面
    // ============================================================

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Dockolate"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.delegate = self
        // 卡片流已能自适应换列，下限放到 420（再窄就是「一行一个」）
        w.minSize = NSSize(width: 420, height: 520)
        w.center()

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.pageBG.cgColor
        w.contentView = root

        // ---- 顶部：标题 + 页面切换 ----
        let title = dkLabel("Dockolate", font: DS.text(15, .semibold), color: DS.ink)
        headerStatus = dkLabel("", font: DS.caption, color: DS.inkTertiary)
        segment = NSSegmentedControl(labels: ["首页", "AI 管理"], trackingMode: .selectOne,
                                     target: self, action: #selector(segmentChanged))
        segment.selectedSegment = 0
        segment.segmentStyle = .rounded
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.setWidth(96, forSegment: 0)
        segment.setWidth(96, forSegment: 1)

        let header = dkHStack([title, headerStatus, dkSpacer(), segment], spacing: 10)
        root.addSubview(header)

        homePage = PageView()
        managerPage = PageView()
        managerPage.isHidden = true
        root.addSubview(homePage)
        root.addSubview(managerPage)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DS.pageInset),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DS.pageInset),
            homePage.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            homePage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            homePage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            homePage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            managerPage.topAnchor.constraint(equalTo: homePage.topAnchor),
            managerPage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            managerPage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            managerPage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        buildHome()
        buildManager()
        window = w
    }

    private func buildHome() {
        // 1) 系统总览
        let overview = CardView(title: "系统总览", subtitle: "Dock 图标同源")
        let tiles = dkHStack([cpuTile, gpuTile, memTile], spacing: 10, align: .top)
        tiles.distribution = .fillEqually
        overview.addRow(tiles)
        memFootnote = dkLabel("", font: DS.caption, color: DS.inkTertiary)
        overview.addRow(memFootnote)
        homePage.addCard(overview)

        // 2) 内存去向
        let memCard = CardView(title: "内存去向", subtitle: "活动监视器口径")
        memBarLabel = dkLabel("", font: DS.summary, color: DS.ink)
        memCard.addRow(memBarLabel)
        memCard.addRow(memBar)
        memLegend = dkLabel("", font: DS.captionMono, color: DS.inkSecondary)
        memCard.addRow(memLegend)
        homePage.addCard(memCard)

        // 3) 本机 AI 模型
        let modelCard = CardView(title: "本机 AI 模型", subtitle: "按内存占用排序")
        for _ in 0..<5 {
            let row = ModelLineView()
            modelCard.addRow(row)
            homeModelRows.append(row)
        }
        homeModelFoot = dkLabel("", font: DS.caption, color: DS.inkTertiary)
        modelCard.addRow(homeModelFoot)
        homePage.addCard(modelCard)

        // 4) 进程三榜
        let procCard = CardView(title: "进程排行", subtitle: "CPU / GPU / 内存")
        let headers = ["CPU 占用最高", "GPU 占用最高（单卡占比）", "内存占用最高"]
        var cols: [NSView] = []
        for c in 0..<3 {
            var views: [NSView] = [dkLabel(headers[c], font: DS.section, color: DS.inkTertiary)]
            var lines: [ProcLineView] = []
            for _ in 0..<3 {
                let l = ProcLineView()
                lines.append(l)
                views.append(l)
            }
            procLines[c] = lines
            let col = dkVStack(views, spacing: 4)
            cols.append(col)
        }
        let row = dkHStack(cols, spacing: 22, align: .top)
        row.distribution = .fillEqually
        procCard.addRow(row)
        homePage.addCard(procCard)
    }

    private func buildManager() {
        // 1) 运行时
        runtimeEmpty = dkLabel("内存里没有正在运行的本地模型。用下面的管理器拉起一个。",
                               font: DS.caption, color: DS.inkTertiary, wrap: true)
        runtimeCard.addRow(runtimeEmpty)
        // 页序：蓄水池 → 运行时 → 管理器 → 工作组（2026-11-02 用户令：蓄水池放最上面）
        managerPage.addCard(poolCard)
        managerPage.addCard(runtimeCard)

        // 2) 模型管理器
        catalogHeader = dkLabel("", font: DS.captionMono, color: DS.inkSecondary, wrap: true)
        catalogCard.addRow(catalogHeader)
        // 排序选择器：选择记进 UserDefaults，下次开机保持
        traySortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        traySortPopup.addItems(withTitles: ["托盘：调用次数", "托盘：名称"])
        traySortPopup.selectItem(at: min(traySort.rawValue, traySortPopup.numberOfItems - 1))
        traySortPopup.target = self
        traySortPopup.action = #selector(sortChanged)
        traySortPopup.controlSize = .small
        modelSortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modelSortPopup.addItems(withTitles: ["模型：调用次数", "模型：名称", "模型：大小"])
        modelSortPopup.selectItem(at: min(modelSort.rawValue, modelSortPopup.numberOfItems - 1))
        modelSortPopup.target = self
        modelSortPopup.action = #selector(sortChanged)
        modelSortPopup.controlSize = .small
        catalogCard.addRow(dkHStack([traySortPopup, modelSortPopup, dkSpacer()], spacing: 8))
        catalogEmpty = dkLabel("正在扫盘…", font: DS.caption, color: DS.inkTertiary, wrap: true)
        catalogCard.addRow(catalogEmpty)
        catalogList.orientation = .vertical
        catalogList.alignment = .leading
        catalogList.spacing = 2
        catalogList.translatesAutoresizingMaskIntoConstraints = false
        catalogCard.addRow(catalogList)
        catalogFoot = dkLabel("", font: DS.caption, color: DS.inkTertiary, wrap: true)
        catalogCard.addRow(catalogFoot)
        let rescan = NSButton(title: "重新扫描", target: self, action: #selector(rescanTapped))
        rescan.bezelStyle = .rounded
        rescan.controlSize = .small
        rescan.font = DS.text(11)
        catalogCard.headerRow.insertArrangedSubview(rescan, at: 2)
        poolCard.addRow(poolBar)
        // 蓄水池已经在这一页最上面（见本方法开头的 addCard 顺序），这里只补内容
        managerPage.addCard(catalogCard)

        // 3) 工作组
        let add = NSButton(title: "＋ 新建", target: self, action: #selector(addGroupTapped))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.font = DS.text(11)
        workgroupCard.headerRow.insertArrangedSubview(add, at: 2)
        workgroupEmpty = dkLabel("还没有工作组。把「要同时驻留的几个模型」取个名字存下来，就能一键拉起。",
                                 font: DS.caption, color: DS.inkTertiary, wrap: true)
        workgroupCard.addRow(workgroupEmpty)
        managerPage.addCard(workgroupCard)
    }

    // ============================================================
    // MARK: 页面切换
    // ============================================================

    @objc private func segmentChanged() { switchPage(segment.selectedSegment) }

    private func switchPage(_ i: Int) {
        homePage.isHidden = i != 0
        managerPage.isHidden = i != 1
        if i == 1 && Date().timeIntervalSince(catalogAt) > 30 { triggerCatalog(force: true) }
        refresh()
    }

    @objc private func rescanTapped() { triggerCatalog(force: true) }

    /// 排序切换：记住选择，强制重建列表
    @objc private func sortChanged() {
        traySort = TraySort(rawValue: traySortPopup.indexOfSelectedItem) ?? .usage
        modelSort = ModelSort(rawValue: modelSortPopup.indexOfSelectedItem) ?? .usage
        UserDefaults.standard.set(traySort.rawValue, forKey: "dk.sortTrays")
        UserDefaults.standard.set(modelSort.rawValue, forKey: "dk.sortModels")
        catalogFingerprint = ""
        rebuildCatalogRows()
    }

    // ============================================================
    // MARK: 采样
    // ============================================================

    private func refresh() {
        guard window != nil else { return }
        // 窗口关掉/最小化后仍然要跑（中枢状态、引擎采样），但没必要 3 秒一次：
        // 降到约 8 秒一跳，前台体验不变、后台 CPU 省一个数量级。
        let idle = !(window?.isVisible ?? false)
        if idle, Date().timeIntervalSince(lastRefreshAt) < 8 { return }
        lastRefreshAt = Date()
        actions.pruneOldStates()

        let s = sampleProvider?() ?? Sample()
        latestSample = s
        if !selfCheckFrozen {
            let residentSum = entries
                .filter { [ModelState.running, .idle, .loading].contains($0.state) }
                .reduce(0.0) { $0 + $1.memGB }
            budget = MemoryBudget(totalGB: s.memTotalGB, usedGB: s.memUsedGB,
                                  reserveGB: config.reserveGB,
                                  wiredGB: s.memWiredGB,
                                  compressedGB: s.memCompressedGB,
                                  modelResidentGB: residentSum)
        }

        // 中枢状态：常驻 daemon（DockolateHub，独立 bundle）正常时由它写；
        // 这里只在状态过期（daemon 没跑/刚挂）时兜底补写，避免两个写者互相覆盖。
        if !selfCheckFrozen && hubStateIsStale() {
            hubSeq += 1
            HubDaemon.writeStateFromGUI(entries: entries, runtime: snapshot,
                                        reserveGB: config.reserveGB, seq: hubSeq)
        }

        updateHome(s)
        updateManagerHeader(s)
        triggerEngineProbeIfNeeded()
        triggerCatalog()
        updateRuntimeRows(s)
        // 蓄水池与清单无关：扫盘没完成时也要按预算先画出来（否则顶部面板空白）
        updatePoolBar()
        updateCatalogRows()
        updateWorkgroupRows()

        headerStatus.stringValue = String(format: "C %.0f%%　G %@　M %.0f%%　｜　可用 %.1f GB（已留 %@ GB 余量）",
                                          s.cpu, s.gpu.map { String(format: "%.0f%%", $0) } ?? "—",
                                          s.memPct, budget.availableGB,
                                          String(format: "%.0f", config.reserveGB))
        updateProcesses()
    }

    private func updateHome(_ s: Sample) {
        cpuTile.update(value: String(format: "%.0f%%", s.cpu),
                       detail: String(format: "全核增量比 · 1s"), pct: s.cpu, color: levelColor(s.cpu))
        let gpuValue = s.gpu.map { String(format: "%.0f%%", $0) } ?? "—"
        gpuTile.update(value: gpuValue,
                       detail: s.gpu == nil ? "本次读不到" : "GPU 客户端时间增量", pct: s.gpu ?? 0,
                       color: s.gpu == nil ? DS.inkTertiary : levelColor(s.gpu!))
        memTile.update(value: String(format: "%.0f%%", s.memPct),
                       detail: String(format: "%.1f / %.0f GB", s.memUsedGB, s.memTotalGB),
                       pct: s.memPct, color: levelColor(s.memPct))
        memFootnote.stringValue = String(format: "Z 压缩+换页 %.0f%%　·　已换页 %.1f GB　·　文件缓存 %.1f GB（可回收）",
                                         s.memPressurePct, s.swapUsedGB, s.memCachedGB)

        memBarLabel.stringValue = String(format: "%.1f / %.0f GB 已用　（%.0f%%）",
                                         s.memUsedGB, s.memTotalGB, s.memPct)
        // 条子必须按「物理内存」加满：已用（应用+联动+压缩）与其余（可回收缓存 + 空闲）互斥，
        // 不能把 vm_stat 的 external 缓存和已用直接并列相加（那会超过物理内存，条子比例就假了）。
        let rest = max(0, s.memTotalGB - s.memUsedGB)
        if s.memDeduped {
            // 应用内存与联动有重叠（GPU 显存既算匿名页也算 wired）：合成一段，别把重叠算两遍
            memBar.segments = [
                .init(value: max(s.memAppGB, s.memWiredGB), color: DS.blue, label: "应用+显存"),
                .init(value: s.memCompressedGB, color: DS.amber, label: "压缩"),
                .init(value: rest, color: NSColor(calibratedWhite: 0.84, alpha: 1), label: "其余"),
            ]
        } else {
            memBar.segments = [
                .init(value: s.memAppGB, color: DS.blue, label: "应用"),
                .init(value: s.memWiredGB, color: DS.purple, label: "内核联动"),
                .init(value: s.memCompressedGB, color: DS.amber, label: "压缩"),
                .init(value: rest, color: NSColor(calibratedWhite: 0.84, alpha: 1), label: "其余"),
            ]
        }
        if s.memDeduped {
            memLegend.stringValue = String(format: "应用 %.1f / 联动 %.1f 有重叠（显存）→ 取 %.1f　+ 压缩 %.1f = 已用 %.1f GB　｜　其余 %.1f（缓存 %.1f · 空闲 %.1f）",
                                           s.memAppGB, s.memWiredGB, max(s.memAppGB, s.memWiredGB),
                                           s.memCompressedGB, s.memUsedGB, rest, s.memCachedGB, s.memFreeGB)
        } else {
            memLegend.stringValue = String(format: "应用 %.1f　+ 内核联动 %.1f　+ 压缩 %.1f　= 已用 %.1f GB　｜　其余 %.1f（文件缓存 %.1f · 空闲 %.1f）",
                                           s.memAppGB, s.memWiredGB, s.memCompressedGB, s.memUsedGB,
                                           rest, s.memCachedGB, s.memFreeGB)
        }

        // 本机 AI 模型
        let rows = Array(snapshot.rows.prefix(homeModelRows.count))
        for (i, row) in homeModelRows.enumerated() {
            if i < rows.count {
                row.isHidden = false
                let resident = rows[i].memGB
            row.update(name: rows[i].name + (rows[i].shared ? " *" : ""), state: rows[i].state, mem: resident)
            } else if i == 0 {
                row.isHidden = false
                row.update(name: "未发现本地模型进程", state: .unregistered, mem: 0)
                row.alphaValue = 0.6
            } else {
                row.isHidden = true
            }
        }
        var footParts: [String] = []
        if snapshot.rows.count > homeModelRows.count {
            footParts.append("另有 \(snapshot.rows.count - homeModelRows.count) 个未显示（去 AI 管理页看全部）")
        }
        if !snapshot.unloaded.isEmpty { footParts.append("未加载 \(snapshot.unloaded.count) 个") }
        if footParts.isEmpty { footParts.append("引擎探测每 4 秒一次；详细指标在 AI 管理页") }
        homeModelFoot.stringValue = footParts.joined(separator: "　·　")
    }

    private func updateManagerHeader(_ s: Sample) {
        catalogCard.setSubtitle(String(format: "可用 %.1f GB / 共 %.0f GB", budget.availableGB, budget.totalGB))
    }

    private func updateProcesses() {
        if selfCheckFrozen {
            let demo: [[(String, String)]] = [
                [("WindowServer", "46.9%"), ("python3", "34.8%"), ("Some-Editor", "33.7%")],
                [("WindowServer", "20.4%"), ("Some-Renderer", "8.6%"), ("Some-Agent", "3.3%")],
                [("Some-Chat-Model", "24.27 GB"), ("Some-Image-Server", "1.99 GB"), ("Some-Agent", "1.12 GB")],
            ]
            for (section, rows) in demo.enumerated() {
                for i in 0..<3 {
                    guard i < procLines[section].count else { continue }
                    if i < rows.count {
                        let color: NSColor? = section == 2 ? nil : levelColor(min(100, Double(rows[i].1.dropLast()) ?? 0))
                        procLines[section][i].update(name: rows[i].0, value: rows[i].1, color: color)
                    } else {
                        procLines[section][i].update(name: "—", value: "", color: nil)
                    }
                }
            }
            return
        }
        let cpu = procSampler.topCPU()
        let gpu = procSampler.topGPU()
        let mem = procSampler.topMemory()
        for (section, stats) in [(0, cpu), (1, gpu), (2, mem)] {
            for i in 0..<3 {
                guard i < procLines[section].count else { continue }
                if i < stats.count {
                    let st = stats[i]
                    let text: String
                    switch section {
                    case 0, 1: text = String(format: "%.1f%%", st.value)
                    default:   text = String(format: "%.2f GB", st.value / 1_073_741_824)
                    }
                    let color: NSColor? = section == 2 ? nil : levelColor(min(100, st.value))
                    procLines[section][i].update(name: st.name, value: text, color: color)
                    procLines[section][i].toolTip = "pid \(st.pid)"
                } else {
                    procLines[section][i].update(name: "—", value: "", color: nil)
                }
            }
        }
    }

    // ============================================================
    // MARK: 引擎探测 / 指标（后台）
    // ============================================================

    private func triggerEngineProbeIfNeeded() {
        guard !selfCheckFrozen else { return }
        guard !engineBusy, Date().timeIntervalSince(engineAt) >= 4 else { return }
        engineBusy = true
        engineAt = Date()
        let recipes = config.recipes
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let snap = self.watcher.refresh()
            var metrics: [String: RuntimeMetric] = [:]
            for row in snap.rows {
                let recipe = recipes.first { $0.matches(name: row.name, path: nil, engine: row.engine, port: row.port) }
                if let m = self.metricsStore.metric(for: row, recipe: recipe) {
                    metrics["\(row.port ?? 0)|\(row.name)"] = m
                }
            }
            DispatchQueue.main.async {
                self.snapshot = snap
                self.metricsByKey = metrics
                self.engineBusy = false
                self.rebuildEntries()
                self.refresh()
            }
        }
    }

    // ============================================================
    // MARK: 扫盘（后台，60 秒 / 手动）
    // ============================================================

    private func triggerCatalog(force: Bool = false) {
        guard !selfCheckFrozen else { return }
        guard !catalogBusy else { return }
        guard force || Date().timeIntervalSince(catalogAt) >= 60 else { return }
        catalogBusy = true
        let started = Date()
        let cfg = config
        let runtime = snapshot
        var roots = ModelInventory.Config().extraDirs
        roots.append(contentsOf: cfg.extraScanRoots)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var invCfg = ModelInventory.Config()
            invCfg.extraDirs = roots
            let inv = ModelInventory()
            inv.engineDirs = runtime.modelDirs
            let units = inv.scan(config: invCfg)
            let rootsAll = (ModelInventory.Config().includeDefaults ? ModelInventory.defaultRoots().map { $0.path } : [])
                + roots + runtime.modelDirs
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                self.diskUnits = units
                self.scanRoots = rootsAll
                self.catalogAt = Date()
                self.catalogSeconds = elapsed
                self.catalogBusy = false
                self.rebuildEntries()          // 用**当前**运行时快照对账（不是扫盘开始那一刻的）
                self.refresh()
            }
        }
    }

    /// 用「缓存的磁盘单元 + 最新运行时快照 + 配方」重新对账。纯内存计算，可以在每次探测后跑。
    private func rebuildEntries() {
        guard !diskUnits.isEmpty else { return }
        entries = ModelCatalog.build(units: diskUnits, runtime: snapshot, config: config,
                                     observed: observed, roots: scanRoots)
        rebuildCatalogRows()
    }

    // ============================================================
    // MARK: 运行时行
    // ============================================================

    private func updateRuntimeRows(_ s: Sample) {
        let running = entries.filter { [.running, .idle, .loading, .failed].contains($0.state) }
        var seen = Set<String>()
        var ordered: [RuntimeRowView] = []
        for e in running {
            let key = e.id
            seen.insert(key)
            let row: RuntimeRowView
            if let r = runtimeRows[key] {
                row = r
            } else {
                row = RuntimeRowView(id: key)
                row.onToggle = { [weak self] in self?.refresh() }
                // 运行时行直接卸载：与模型管理器同一动作（actions.stop），不用回下面去找这张卡
                row.onStop = { [weak self] in
                    guard let self = self else { return }
                    self.actions.stop(e)
                    self.refresh()
                }
                row.setExpanded(expandedRuntime.contains(key))
                runtimeRows[key] = row
                runtimeCard.addRow(row)
            }
            let metric = metricsByKey["\(e.port ?? 0)|\(e.runtimeName.isEmpty ? e.title : e.runtimeName)"]
            // 与内存池同口径：进程 RSS
            let residentGB = e.memGB
            let act = actions.state(for: e.id)
            row.update(name: e.title, engine: e.engineName,
                       state: e.state, memGB: residentGB, metric: metric, action: act,
                       canStop: e.canStop, busy: (act?.phase.isBusy ?? false),
                       blockedReason: e.blockedReason)
            row.isHidden = false
            ordered.append(row)
        }
        for (k, r) in runtimeRows where !seen.contains(k) {
            r.removeFromSuperview()
            runtimeRows[k] = nil
        }
        runtimeEmpty.isHidden = !running.isEmpty
        // 顺序：running 在前（entries 已排好），按需重排
        for (i, r) in ordered.enumerated() {
            if runtimeCard.body.arrangedSubviews.contains(r) {
                runtimeCard.body.removeArrangedSubview(r)
                runtimeCard.body.insertArrangedSubview(r, at: 1 + i)   // 0 是说明行
            }
        }
    }

    // ============================================================
    // MARK: 目录行
    // ============================================================

    private func rebuildCatalogRows() {
        // 部件（LoRA / 视觉投影 / VAE / 文本编码器…）默认不进列表：
        // 它们不是能启动的模型，混在卡片里只会淹没真正的条目（2026-11-04 用户裁定）。
        // 需要围观时：defaults write com.autugit.dockolate dk.showParts -bool YES
        let showParts = UserDefaults.standard.bool(forKey: "dk.showParts")
        let visible = showParts ? entries : entries.filter { !$0.hidden && $0.category != .part }
        // 指纹含状态、可见集与排序：任一变化都要重建
        let fingerprint = (showParts ? "P|" : "-|") + "\(traySort.rawValue)|\(modelSort.rawValue)|"
            + visible.map { $0.id + ":" + $0.state.text }.joined(separator: "|")
        guard fingerprint != catalogFingerprint else { return }
        catalogFingerprint = fingerprint

        for v in catalogList.arrangedSubviews { catalogList.removeArrangedSubview(v); v.removeFromSuperview() }
        catalogRows.removeAll()
        catalogTileHeights.removeAll()

        // 排序：在跑的置顶 → 分类顺序 → 名称。
        // ⛔ 不按大小降序：那样首屏全是最高的方块，一列只放得下两块（用户反馈的原状）。
        // 混排之后，矮块会把列填满，同样的可视高度能看到更多方块。
        // 模型的排序（用户选项：调用次数 / 名称 / 大小）
        func usageOf(_ e: CatalogEntry) -> Int {
            if let n = usageCounts[e.id] { return n }
            let key = "\(e.port ?? 0)|\(e.runtimeName.isEmpty ? e.title : e.runtimeName)"
            return metricsByKey[key]?.requests ?? 0
        }
        let ordered: [CatalogEntry]
        switch modelSort {
        case .name:
            ordered = visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size:
            ordered = visible.sorted {
                let a = tileSize($0), b = tileSize($1)
                if a != b { return a > b }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .usage:
            ordered = visible.sorted {
                let a = usageOf($0), b = usageOf($1)
                if a != b { return a > b }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        let maxSize = max(1, ordered.map { tileSize($0) }.max() ?? 1)

        // ---- 引擎托盘：把卡片按「能启动它的引擎」分组 ----
        // 引擎=托盘（2026-11-04 用户裁定）。归属只认事实，不猜：
        //   ① 配方声明的 engine  ② 运行时引擎自报  ③ 都没有 ⇒ 「未绑定引擎」托盘。
        func trayName(_ e: CatalogEntry) -> String {
            if let eng = e.recipe?.engine, !eng.isEmpty { return eng }
            if !e.engineName.isEmpty { return e.engineName }
            return "未绑定引擎"
        }
        var trays: [String: [CatalogEntry]] = [:]
        var trayOrder: [String] = []
        for e in ordered {
            let t = trayName(e)
            if trays[t] == nil { trays[t] = []; trayOrder.append(t) }
            trays[t]?.append(e)
        }
        trayOrder.sort { a, b in
            if a == "未绑定引擎" { return false }
            if b == "未绑定引擎" { return true }
            switch traySort {
            case .name:
                return a.localizedStandardCompare(b) == .orderedAscending
            case .usage:
                // 托盘没有「大小」，用「成员调用次数之和」当热度
                let au = (trays[a] ?? []).reduce(0) { $0 + usageOf($1) }
                let bu = (trays[b] ?? []).reduce(0) { $0 + usageOf($1) }
                if au != bu { return au > bu }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
        }

        for tray in trayOrder {
            let group = trays[tray] ?? []
            let resident = group.filter { [ModelState.running, .idle, .loading].contains($0.state) }
                .reduce(0.0) { $0 + $1.memGB }
            var head = "▸ " + tray + " · \(group.count) 个"
            if resident > 0.05 { head += String(format: " · 常驻 %.1f GB", resident) }
            if tray == "未绑定引擎" { head += "（没有配方，也就没有可启动它的引擎）" }
            let trayHeader = dkLabel(head, font: DS.text(12.5, .semibold), color: DS.inkTertiary)
            catalogList.addArrangedSubview(trayHeader)
            trayHeader.leadingAnchor.constraint(equalTo: catalogList.leadingAnchor, constant: 4).isActive = true

            let grid = FlowGridView()
            grid.minItemWidth = 236
            var cards: [NSView] = []
            var heights: [CGFloat] = []
            for e in group {
            let row = CatalogRowView(id: e.id)
            row.onLaunch = { [weak self] in
                guard let self = self else { return }
                // 互斥判定交给中枢（registry.json 的 mutexWith），GUI 不再自己猜「有别的模型在跑」。
                self.hubAdmit(entry: e) { ok in
                    guard ok else { return }
                    self.actions.launch(e)
                    self.refresh()
                }
            }
            row.onStop = { [weak self] in
                guard let self = self else { return }
                self.actions.stop(e)
                self.refresh()
            }
            row.onEditPolicy = { [weak self] in
                guard let self = self, let w = self.window,
                      let pol = HubPolicies.policy(for: e) else { return }
                let known = HubPolicies.registry.entries.keys
                    .filter { $0 != pol.id }.sorted()
                self.policySheet.present(in: w, policy: pol, knownModels: known) { updated in
                    guard updated != nil else { return }
                    HubPolicies.refresh()
                    self.hubRegistry = HubRegistry.load()
                    self.refresh()
                }
            }
            catalogRows[e.id] = row
            cards.append(row)
            let h = tileHeight(size: tileSize(e), maxSize: maxSize)
            catalogTileHeights[e.id] = h
            heights.append(h)
        }
        grid.setItems(cards, heights: heights)
        catalogList.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: catalogList.widthAnchor).isActive = true
        }   // ← 一个托盘结束
        catalogEmpty.isHidden = !visible.isEmpty
        let folded = entries.count - visible.count
        catalogEmpty.stringValue = visible.isEmpty
            ? "没扫到任何模型。检查扫描目录，或在 registry.json 的 recipes 里加配方。"
            : ""
        if folded > 0, catalogHeader.stringValue.contains("折叠") == false {
            catalogHeader.stringValue += "　·　已折叠 \(folded) 个部件"
        }
    }

    /// 方块大小口径 = 估算内存（权重 + 开销）；拿不到就退回盘占
    private func tileSize(_ e: CatalogEntry) -> Double {
        e.estMemGB > 0.01 ? e.estMemGB : e.diskGB
    }

    /// 高度比例（DESIGN.md §3.3，2026-11-02 用户裁定）：
    ///   h = Hmin + (Hmax − Hmin)·sqrt(size / sizeMax)
    /// 凹函数——大小差得越多，高度差反而收窄，小方块不会被压到看不清；
    /// 同一条曲线也用在内存池的段长上，两处编码口径一致。
    /// 低于 compactBelow 的方块进「紧凑态」：只留名称 / 盘占 / 按钮，藏掉副标题，
    /// 这样小模型真的只有一小块，一列能塞下好几个。
    private func tileHeight(size: Double, maxSize: Double) -> CGFloat {
        guard maxSize > 0, size > 0 else { return 112 }
        let t = CGFloat((size / maxSize).squareRoot())
        return (112 + (216 - 112) * max(0, min(1, t))).rounded()
    }

    /// 紧凑阈值（pt）：低于它的方块藏副标题
    private func isCompactTile(_ height: CGFloat) -> Bool { height < 150 }

    /// 状态文件是否过期（>10 秒没更新 ⇒ 后台不在，需要 GUI 兜底写）
    private func hubStateIsStale() -> Bool {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: HubDaemon.statePath)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ts = obj["generated_at"] as? String,
              let date = ISO8601DateFormatter().date(from: ts) else { return true }
        return Date().timeIntervalSince(date) > 10
    }

    /// 中枢后台是否在刷新（读 hub-state.json 的 generated_at，不复用采样结果）
    private var hubStatusText: String {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: HubDaemon.statePath)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ts = obj["generated_at"] as? String,
              let date = ISO8601DateFormatter().date(from: ts) else {
            return "中枢：未运行"
        }
        let age = Date().timeIntervalSince(date)
        let writer = (obj["writer"] as? String) == "gui" ? "界面兜底" : "后台"
        if age > 30 { return String(format: "中枢：状态已停 %.0f 秒", age) }
        return String(format: "中枢：运行中（%@，%.0f 秒前刷新，%d 条策略）",
                      writer, age, hubRegistry.count)
    }

    /// 池条数据：模型驻留取引擎自报（ram_used），凸出量 = 权重体积 − 驻留
    private func updatePoolBar() {
        let running = entries.filter { [.running, .idle, .loading].contains($0.state) && $0.port != nil }
        var slots: [MemoryReservoirView.ModelSlot] = []
        for e in running {
            // 驻留量 = 进程**树** RSS（启动器 + 引擎子进程）。footprint 不计 mmap 的权重页
            // （实测 125B：18 GB ↔ RSS 53.6 GB），会把最大的模型错记成「系统与其他」。
            let resident = e.pid.flatMap { MemoryPoolBar.subtreeRSSGiB(rootPid: $0) } ?? e.memGB
            let color: NSColor
            switch e.state {
            case .running, .idle: color = DS.blue
            case .loading:        color = DS.amber
            case .failed:         color = DS.red
            default:              color = DS.green
            }
            slots.append(.init(name: e.title, residentGiB: resident,
                               weightGiB: max(e.diskGB, resident), color: color))
        }
        poolBar.update(totalGiB: budget.totalGB,
                       usedGiB: budget.usedGB,
                       reserveGiB: config.reserveGB,
                       wiredGiB: latestSample.memWiredGB,
                       compressedGiB: latestSample.memCompressedGB,
                       swapGiB: MemoryPoolBar.swapUsedGiB(),
                       slots: slots)
        poolCard.setSubtitle(String(format: "物理 %.0f GB · 已用 %.1f · 预留 %.0f · %d 个漂在池里",
                                    budget.totalGB, budget.usedGB, config.reserveGB, slots.count))
    }

    private func updateCatalogRows() {
        guard !catalogRows.isEmpty || !entries.isEmpty else { return }
        hubRegistry = HubRegistry.load()
        HubPolicies.refresh()
        for e in entries {
            guard let row = catalogRows[e.id] else { continue }
            let fit: FitLevel = [.running, .idle, .loading].contains(e.state)
                ? .running
                : (e.category == .part || e.estMemGB <= 0
                    ? .unavailable
                    : MemoryBudget.fit(estGB: e.estMemGB, budget: budget))
            let key = "\(e.port ?? 0)|\(e.runtimeName.isEmpty ? e.title : e.runtimeName)"
            // 累计调用次数：引擎计数可能重启归零，用「增量」累加才不会丢历史
            if let m = metricsByKey[key] {
                let seen = lastSeenRequests[key] ?? 0
                if m.requests > seen {
                    usageCounts[e.id, default: 0] += (m.requests - seen)
                    lastSeenRequests[key] = m.requests
                    UserDefaults.standard.set(usageCounts, forKey: "dk.usageCounts")
                } else if m.requests < seen {
                    lastSeenRequests[key] = m.requests      // 引擎重启，基准归零
                }
            }
            row.update(entry: e, fit: fit, action: actions.state(for: e.id),
                       policy: hubRegistry.entry(for: e.id, recipe: e.recipe?.id),
                       metric: metricsByKey[key],
                       compact: isCompactTile(catalogTileHeights[e.id] ?? 216))
        }
        let launchable = entries.filter { $0.canLaunch }.count
        let unconfigured = entries.filter { !$0.canLaunch && $0.state == .unregistered }.count
        catalogHeader.stringValue = String(
            format: "可用 %.1f GB（总 %.0f − 已用 %.0f − 余量 %.0f）　·　%d 个权重，%d 个可拉起%@　·　扫描 %.1fs　·　%@",
            budget.availableGB, budget.totalGB, budget.usedGB, config.reserveGB,
            entries.count, launchable,
            unconfigured > 0 ? "，\(unconfigured) 个未配置启动方式" : "", catalogSeconds,
            hubStatusText)

        var foot: [String] = []
        if !config.recipes.isEmpty { foot.append("配方 \(config.recipes.count) 条") }
        if !config.warnings.isEmpty { foot.append(config.warnings.joined(separator: "；")) }
        foot.append("三色判据：≤ 可用×85% 绿（宽裕）｜ ≤ 可用 黄（勉强）｜ > 可用 红（放不下）；估算 = 权重 + 开销，跑过一次后改用实测峰值")
        catalogFoot.stringValue = foot.joined(separator: "\n")
    }

    // ============================================================
    // MARK: 工作组
    // ============================================================

    private func updateWorkgroupRows() {
        var seen = Set<String>()
        for (i, g) in groups.enumerated() {
            seen.insert(g.id)
            let row: WorkgroupRowView
            if let r = workgroupRows[g.id] {
                row = r
            } else {
                row = WorkgroupRowView(id: g.id)
                row.onLaunch = { [weak self] in
                    guard let self = self else { return }
                    let memberIDs = Set(g.members)
                    if let busy = self.entries.first(where: {
                        !memberIDs.contains($0.id) && [.running, .idle, .loading].contains($0.state)
                    }) {
                        let a = NSAlert()
                        a.messageText = "已有模型驻留内存"
                        a.informativeText = "「\(busy.title)」正占着内存。\n"
                            + "启动这个工作组可能会把其它模型卸载掉。要继续吗？"
                        a.addButton(withTitle: "取消")
                        a.addButton(withTitle: "继续启动")
                        NSApp.activate(ignoringOtherApps: true)
                        if a.runModal() != .alertFirstButtonReturn { return }
                    }
                    self.actions.launchGroup(g, entries: self.entries)
                    self.refresh()
                }
                row.onStop = { [weak self] in
                    guard let self = self else { return }
                    self.actions.stopGroup(g, entries: self.entries)
                    self.refresh()
                }
                row.onDelete = { [weak self] in
                    guard let self = self else { return }
                    self.groups.removeAll { $0.id == g.id }
                    WorkgroupStore.save(self.groups)
                    self.refresh()
                }
                workgroupRows[g.id] = row
                workgroupCard.addRow(row)
            }
            let members = g.members.compactMap { id in entries.first { $0.id == id } }
            let total = members.reduce(0) { $0 + $1.estMemGB }
            let resident = members.filter { [.running, .idle, .loading].contains($0.state) }
            let need = total - resident.reduce(0) { $0 + $1.estMemGB }
            let fit = members.isEmpty ? FitLevel.unavailable : MemoryBudget.fit(estGB: need, budget: budget)
            row.update(group: g, members: members, fit: fit, action: actions.state(for: "group:" + g.id))
            // 顺序稳定
            if workgroupCard.body.arrangedSubviews.contains(row) {
                workgroupCard.body.removeArrangedSubview(row)
                workgroupCard.body.insertArrangedSubview(row, at: i)
            }
        }
        for (k, r) in workgroupRows where !seen.contains(k) {
            r.removeFromSuperview()
            workgroupRows[k] = nil
        }
        workgroupEmpty.isHidden = !groups.isEmpty
    }

    @objc private func addGroupTapped() {
        guard let w = window else { return }
        sheet.present(in: w, entries: entries, existing: groups) { [weak self] g in
            guard let self = self, let g = g else { return }
            self.groups.append(g)
            WorkgroupStore.save(self.groups)
            self.refresh()
        }
    }

    // ============================================================
    // MARK: 自检（无屏幕录制权限时的验收面）
    // ============================================================

    /// 注入演示数据：覆盖四种状态色 + 各种可行性 + 一个工作组
    func selfCheckInjectDemo() {
        if window == nil { build(); start() }
        selfCheckFrozen = true

        config = LauncherConfig.load()
        var snap = ModelSnapshot()
        snap.enginesFound = 1
        snap.rows = [
            ModelRow(name: "Some-Chat-Model-27B", memGB: 12.0, state: .running,
                     note: "pid 4242 · MyEngine · 端口 12345", port: 12345, engine: "MyEngine"),
            ModelRow(name: "Some-Image-Model", memGB: 6.0, state: .running,
                     note: "pid 4343 · ImageEngine · 端口 12346", port: 12346, engine: "ImageEngine"),
            ModelRow(name: "Some-Video-Model", memGB: 10.0, state: .running,
                     note: "pid 4444 · VideoEngine · 端口 12347", port: 12347, engine: "VideoEngine"),
        ]
        snapshot = snap
        let imageMedia = MediaMetric(kind: .image, rounds: 6,
                                     durations: [44.6, 43.7, 45.2, 44.1, 43.9, 44.8],
                                     currentElapsedS: 12.4, currentIndex: 7,
                                     lastAt: Date().addingTimeInterval(-18),
                                     source: "ComfyUI /queue + /history（自本次启动）")
        let videoMedia = MediaMetric(kind: .video, rounds: 3,
                                     durations: [78.4, 81.2, 74.9],
                                     currentElapsedS: 41.3, currentIndex: 4,
                                     currentStep: 12, currentStepTotal: 20,
                                     lastFrames: 124, lastSize: "576×384",
                                     lastAt: Date().addingTimeInterval(-64),
                                     source: "mlx-serve 日志（自本次启动）")
        metricsByKey = [
            "12345|Some-Chat-Model-27B": RuntimeMetric(uptime: 8123, prefillTokS: 1684, decodeTokS: 53.2,
                                                      requests: 42, tokensIn: 184_320, tokensOut: 92_114,
                                                      ttftAvgS: 0.42, source: "Splash 日志 · 自本次加载起",
                                                      lastRequestAt: Date().addingTimeInterval(-42)),
            "12346|Some-Image-Model": RuntimeMetric(uptime: 2630, source: imageMedia.source, media: imageMedia),
            "12347|Some-Video-Model": RuntimeMetric(uptime: 3725, source: videoMedia.source, media: videoMedia),
        ]
        entries = [
            CatalogEntry(id: "demo1", title: "Some-Chat-Model-27B · 4bit", subtitle: "用户模型目录 · ~/models/Sample",
                         category: .chat, diskGB: 28.0, estMemGB: 26.4, estBasis: "实测峰值 26.4 GB",
                         state: .running, memGB: 12.0, port: 12345, pid: 4242, runtimeName: "Some-Chat-Model-27B",
                         canStop: true),
            CatalogEntry(id: "demo2", title: "Some-Flash-Model-125B · IQ3_S", subtitle: "自定义目录 · /models/Sample-125B",
                         category: .chat, diskGB: 78.1, estMemGB: 82.0, estBasis: "权重 78.1 GB + 开销估算 11.7 GB",
                         canLaunch: true),
            // 三色里的「黄」：估算刚好压在可用内存以内、但没富余（验收配色时必须有这一档）
            CatalogEntry(id: "demo7", title: "Some-Tight-Model · 4bit", subtitle: "自定义目录 · /models/Sample-Tight",
                         category: .chat, diskGB: 19.0, estMemGB: 21.0, estBasis: "权重 19.0 GB + 开销估算 2.0 GB",
                         canLaunch: true),
            CatalogEntry(id: "demo3", title: "Some-Image-Model · 8bit", subtitle: "自定义目录 · /models/Sample-Image",
                         category: .image, diskGB: 20.0, estMemGB: 18.0, estBasis: "权重 16.1 GB + 开销估算 1.9 GB",
                         state: .running, memGB: 6.0, port: 12346, pid: 4343, runtimeName: "Some-Image-Model",
                         canStop: true),
            CatalogEntry(id: "demo4", title: "Some-Video-Model · 4bit", subtitle: "自定义目录 · /models/Sample-Video",
                         category: .video, diskGB: 30.0, estMemGB: 22.0, estBasis: "权重 18.0 GB + 开销估算 4.0 GB",
                         state: .running, memGB: 10.0, port: 12347, pid: 4444, runtimeName: "Some-Video-Model",
                         canStop: true),
            CatalogEntry(id: "demo5", title: "Some-Embedding", subtitle: "用户模型目录 · ~/mlx-models/Sample-Embed",
                         category: .embedding, diskGB: 1.1, estMemGB: 1.2, estBasis: "权重 1.1 GB + 开销估算 0.1 GB",
                         canLaunch: true),
            CatalogEntry(id: "demo6", title: "Some-Image-Model · VAE", subtitle: "自定义目录 · /models/Sample-Image/vae",
                         category: .part, diskGB: 1.26, estMemGB: 1.26, estBasis: "权重 1.3 GB",
                         canLaunch: false, blockedReason: "部件随主模型一起加载，不能单独拉起",
                         parts: ["Some-Image-Model（VAE）"]),
        ]
        groups = [Workgroup(id: "wg-demo", name: "27B + 生图", members: ["demo1", "demo3"])]
        budget = MemoryBudget(totalGB: 64, usedGB: 35.8, reserveGB: 6)
        // 演示时把「生图 / 视频」两行展开：这两行的展开区是新口径（当前这轮 · 每轮耗时 · 来源）
        expandedRuntime.insert("demo3")
        expandedRuntime.insert("demo4")
        rebuildCatalogRows()
        updateRuntimeRows(Sample())
        updateCatalogRows()
        updateWorkgroupRows()
        catalogHeader.stringValue = "可用 22.2 GB（总 64 − 已用 35.8 − 余量 6）　·　6 个权重，3 个可拉起　·　扫描 2.8s"
        catalogFoot.stringValue = "三色判据：≤ 可用×85% 绿（宽裕）｜ ≤ 可用 黄（勉强）｜ > 可用 红（放不下）；估算 = 权重 + 开销，跑过一次后改用实测峰值"
    }

    /// 单独渲染蓄水池（设计迭代用：池子在模型管理器下面，整页截图常常截不到）
    /// 蓄水池演示数据（截图 / 验收用，与真机数字无关）：
    /// `--demo-pool` 正常态（有空闲、有空闲块内名字）；`--demo-pool=overflow` 已用超出物理内存（验红色溢出）。
    func selfCheckPoolDemo(overflow: Bool) {
        if overflow {
            poolBar.update(totalGiB: 64, usedGiB: 70, reserveGiB: 6,
                           wiredGiB: 43, compressedGiB: 6, swapGiB: 2.4,
                           slots: [
                            .init(name: "Some-Chat-Model-27B", residentGiB: 24, weightGiB: 28, color: DS.blue),
                            .init(name: "Some-Image-Model", residentGiB: 16, weightGiB: 20, color: DS.amber),
                            .init(name: "Some-Video-Model", residentGiB: 15, weightGiB: 38, color: DS.blue),
                           ])
        } else {
            poolBar.update(totalGiB: 64, usedGiB: 50, reserveGiB: 6,
                           wiredGiB: 43, compressedGiB: 6, swapGiB: 0.4,
                           slots: [
                            .init(name: "Some-Chat-Model-27B", residentGiB: 18, weightGiB: 28, color: DS.blue),
                            .init(name: "Some-Image-Model", residentGiB: 10, weightGiB: 20, color: DS.amber),
                            .init(name: "Some-Video-Model", residentGiB: 8, weightGiB: 30, color: DS.blue),
                           ])
        }
    }

    /// 蓄水池几何导出（验收用；与 draw 共用同一份布局计算）
    func selfCheckDumpPool() {
        for line in poolBar.debugDump() { print(line) }
    }

    func selfCheckRenderPool(to path: String, width: CGFloat = 680) -> Bool {
        let v = poolBar
        v.frame = NSRect(x: 0, y: 0, width: width, height: 100)   // 先给宽度：固有高度随宽度换版式
        v.frame = NSRect(x: 0, y: 0, width: width, height: v.intrinsicContentSize.height)
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        v.needsDisplay = true
        v.displayIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            DS.pageBG.setFill()
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

    /// 方块几何导出（验收用）：id / y / 高度 / x / 宽度。数值来自真实 frame，不靠看图估。
    func selfCheckDumpTiles() {
        let rows = catalogRows.values.sorted { $0.frame.minY < $1.frame.minY }
        print("tiles=\(rows.count)")
        for r in rows {
            let f = r.frame
            print(String(format: "%@  y=%7.1f  h=%6.1f  x=%7.1f  w=%6.1f",
                         r.entryID, f.minY, f.height, f.minX, f.width))
        }
    }

    func selfCheckRenderPNG(to path: String, page: Int, tallHeight: CGFloat? = nil) -> Bool {
        guard let w = window, let v = w.contentView else { return false }
        if let h = tallHeight {
            var f = w.frame
            let top = f.origin.y + f.height
            f.size.height = h
            f.origin.y = top - h
            w.setFrame(f, display: true)
        }
        segment.selectedSegment = page
        switchPage(page)
        v.layoutSubtreeIfNeeded()
        // 等一轮 runloop，让 stack view 把隐藏行收起来
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            DS.pageBG.setFill()
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

// ============================================================
// MARK: - 分类的视觉语言（形状 + 配色，一眼可辨）
// ------------------------------------------------------------
// 用户裁定（2026-11-04）：不同类型的模型必须一眼能分野，不能只靠一行小字。
// 两个通道同时给：SF Symbol 的形状不同（文字气泡 / 相片 / 胶片 / 声波 / 网格 / 齿轮），
// 配色也不同（蓝 / 紫 / 橙 / 青 / 靛 / 灰）。
// ============================================================

extension ModelCategory {
    var symbol: String {
        switch self {
        case .chat:      return "text.bubble"
        case .image:     return "photo"
        case .video:     return "film"
        case .audio:     return "waveform"
        case .embedding: return "square.grid.3x3"
        case .service:   return "gearshape"
        case .part:      return "puzzlepiece"
        case .other:     return "questionmark.circle"
        }
    }

    var accent: NSColor {
        switch self {
        case .chat:      return .systemBlue
        case .image:     return .systemPurple
        case .video:     return .systemOrange
        case .audio:     return .systemTeal
        case .embedding: return .systemIndigo
        case .service:   return .systemGray
        case .part:      return .tertiaryLabelColor
        case .other:     return .systemGray
        }
    }
}

// ============================================================
// MARK: - 类型视觉的取值入口（数据优先，代码里的只是兜底）
// ------------------------------------------------------------
// registry.json 写 `categoryVisuals` 就能改图标与配色，不用重编译；
// 5 秒缓存一次，避免每张卡片每次刷新都读盘。
// ============================================================

enum ModelVisuals {
    private static var cache: (data: ClassifyData, at: Date)?

    static func data() -> ClassifyData {
        if let c = cache, Date().timeIntervalSince(c.at) < 5 { return c.data }
        let d = ClassifyData.loadFromRegistry()
        cache = (d, Date())
        return d
    }

    static func symbol(_ c: ModelCategory) -> String {
        data().visualSymbol(c) ?? c.symbol
    }

    static func color(_ c: ModelCategory) -> NSColor {
        guard let name = data().visualColorName(c)?.lowercased() else { return c.accent }
        return namedColors[name] ?? c.accent
    }

    /// 允许的颜色名（SF Symbol 之外的都回落内置配色，写错不会变成透明）
    private static let namedColors: [String: NSColor] = [
        "blue": .systemBlue, "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow,
        "green": .systemGreen, "mint": .systemMint, "teal": .systemTeal, "cyan": .systemCyan,
        "purple": .systemPurple, "pink": .systemPink, "indigo": .systemIndigo, "brown": .systemBrown,
        "gray": .systemGray, "grey": .systemGray,
        "label": .labelColor, "secondary": .secondaryLabelColor,
    ]
}
