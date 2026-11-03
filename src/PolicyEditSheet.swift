// ============================================================
// 策略编辑面板（写回 registry.json）
// ============================================================
//
// 用户 2026-10-29 要求：策略不能只在界面上「看得见」，还要能改。
// 真源仍是 registry.json —— 这里只负责「把改动写回去」，不引入第二份配置。
//
// 写回原则：
//   · 只改这个模型的策略字段，其它字段（aliases / capability / recipe …）原样保留
//   · 原子写 + 先备份（registry.json.bak.<时间戳>），写坏了能立刻回滚
//   · 校验放在保存前：不能把自己列进互斥、互斥名不能重复

import AppKit

final class PolicyEditSheet: NSObject {

    private var window: NSWindow?
    private var residentSwitch: NSButton!
    private var autoStartSwitch: NSButton!
    private var restartSwitch: NSButton!
    private var exposedSwitch: NSButton!
    private var groupField: NSTextField!
    private var mutexField: NSTextField!
    private var hintLabel: NSTextField!
    private var done: ((HubPolicyEntry?) -> Void)?
    private var policy: HubPolicyEntry!

    func present(in parent: NSWindow, policy: HubPolicyEntry, knownModels: [String],
                 done: @escaping (HubPolicyEntry?) -> Void) {
        self.policy = policy
        self.done = done

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "策略：\(policy.id)"
        w.isReleasedWhenClosed = false
        window = w

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content

        residentSwitch = checkbox("驻留内存（拉起后不主动卸载）", on: policy.resident)
        autoStartSwitch = checkbox("开机自启", on: policy.autoStart)
        restartSwitch = checkbox("被卸载后自动重拉（自回归）", on: policy.restartOnCrash)
        exposedSwitch = checkbox("出现在对外模型列表里", on: policy.exposed)

        groupField = NSTextField(string: policy.group ?? "")
        groupField.placeholderString = "留空 = 不属于任何组"
        groupField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        mutexField = NSTextField(string: policy.mutexWith.joined(separator: ", "))
        mutexField.placeholderString = "用逗号分隔"
        mutexField.widthAnchor.constraint(equalToConstant: 400).isActive = true

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = DS.caption
        hintLabel.textColor = DS.inkTertiary
        hintLabel.maximumNumberOfLines = 3
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.widthAnchor.constraint(equalToConstant: 400).isActive = true
        if knownModels.isEmpty {
            hintLabel.stringValue = "互斥对象填模型名（例如另一个大模型）；本机只跑一个本地模型时，互斥关系是最有效的保护。"
        } else {
            hintLabel.stringValue = "可互斥的模型：" + knownModels.prefix(4).joined(separator: "、")
        }

        root.addArrangedSubview(sectionTitle("调度"))
        root.addArrangedSubview(residentSwitch)
        root.addArrangedSubview(autoStartSwitch)
        root.addArrangedSubview(restartSwitch)
        root.addArrangedSubview(sectionTitle("对外"))
        root.addArrangedSubview(exposedSwitch)
        root.addArrangedSubview(sectionTitle("分组 / 互斥"))
        root.addArrangedSubview(labelled("组", groupField))
        root.addArrangedSubview(labelled("互斥", mutexField))
        root.addArrangedSubview(hintLabel)
        root.addArrangedSubview(spacer())
        root.addArrangedSubview(buttons())

        parent.beginSheet(w)
    }

    // ---- 控件工厂 ----

    private func checkbox(_ title: String, on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        b.font = DS.text(12)
        return b
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = DS.section
        l.textColor = DS.inkTertiary
        return l
    }

    private func labelled(_ name: String, _ field: NSView) -> NSView {
        let l = NSTextField(labelWithString: name)
        l.font = DS.text(12)
        l.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let row = NSStackView(views: [l, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }

    private func buttons() -> NSView {
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        for b in [cancel, save] { b.bezelStyle = .rounded }
        let row = NSStackView(views: [NSView(), cancel, save])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return row
    }

    // ---- 动作 ----

    @objc private func cancelTapped() {
        if let w = window, let p = w.sheetParent { p.endSheet(w) }
        done?(nil)
    }

    @objc private func saveTapped() {
        var p = policy!
        p.resident = residentSwitch.state == .on
        p.autoStart = autoStartSwitch.state == .on
        p.restartOnCrash = restartSwitch.state == .on
        p.exposed = exposedSwitch.state == .on
        let g = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        p.group = g.isEmpty ? nil : g
        // 互斥：逗号/中文逗号/空格都当分隔符；去重；不许包含自己
        let raw = mutexField.stringValue
            .replacingOccurrences(of: "，", with: ",")
            .split(whereSeparator: { ", ;、\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != p.id }
        p.mutexWith = Array(NSOrderedSet(array: raw)) as? [String] ?? raw

        do {
            try HubRegistry.savePolicy(p)
        } catch {
            let a = NSAlert()
            a.messageText = "写回 registry.json 失败"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "好")
            a.runModal()
            return
        }

        if let w = window, let parent = w.sheetParent { parent.endSheet(w) }
        done?(p)
    }
}
