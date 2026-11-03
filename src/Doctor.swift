// ============================================================
// 自检（--doctor）与「程序本体被改过」检测
// ============================================================
//
// 背景（2026-11-03 用户要求）：程序要能被 AI 深度调用，但**程序本体不能被误改坏**。
// 单靠权限做不到（同用户可写），所以先做「可发现」：
//   · build.sh 在签名前把 bundle 内每个文件的 SHA-256 写进 Contents/Resources/manifest.json
//   · 启动时与 `--doctor` 对比哈希 + 验签 → 明确告诉人/AI「哪个文件被改过」
//   · 状态文件（SupportDir）**不在**清单里 —— 它本来就是给人和 AI 改的
//
// 这里刻意只「报告」不「阻断」：开发时改二进制再跑是正常流程，
// 真正治本的是把 App 装到 /Applications 并由 root 拥有（tools/install-system.command）。

import Foundation
import AppKit
import CryptoKit

enum Doctor {

    struct Check {
        let name: String
        let ok: Bool
        let detail: String
    }

    static var bundleURL: URL { Bundle.main.bundleURL }
    static var bundlePath: String { bundleURL.path }

    private static func sha256(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// 清单校验：返回 (是否齐全一致, 明细行)
    static func checkManifest() -> (ok: Bool, lines: [String]) {
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/manifest.json")
        guard let d = try? Data(contentsOf: manifestURL),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let files = obj["files"] as? [[String: Any]] else {
            return (false, ["缺 manifest.json（这份 bundle 不是 build.sh 产出的，或清单被删）"])
        }
        var lines: [String] = []
        var ok = true
        for f in files {
            guard let rel = f["path"] as? String, let want = f["sha256"] as? String else { continue }
            let url = bundleURL.appendingPathComponent(rel)
            guard let got = sha256(url) else {
                ok = false
                lines.append("缺文件：\(rel)")
                continue
            }
            if got != want {
                ok = false
                lines.append("被改过：\(rel)（期望 \(want.prefix(12))… 实际 \(got.prefix(12))…）")
            }
        }
        if ok { lines.append("\(files.count) 个文件哈希一致") }
        return (ok, lines)
    }

    private static func checkSignature() -> (ok: Bool, detail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", bundlePath]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return (false, "codesign 起不来：\(error.localizedDescription)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus == 0 { return (true, "签名与封存资源一致") }
        return (false, out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).description)
    }

    private static func checkBundleWritable() -> (ok: Bool, detail: String) {
        let bin = bundleURL.appendingPathComponent("Contents/MacOS/Dockolate").path
        let writable = FileManager.default.isWritableFile(atPath: bin)
        if writable {
            return (true, "当前用户**可写**程序本体（\(bundlePath)）——能被同用户进程覆盖；要硬隔离请用 tools/install-system.command 装到 /Applications")
        }
        return (true, "程序本体对当前用户只读（\(bundlePath)）")
    }

    private static func checkStateDir() -> (ok: Bool, lines: [String]) {
        var lines: [String] = []
        var ok = true
        let dir = SupportDir.dir
        if !FileManager.default.fileExists(atPath: dir) {
            return (true, ["还没有状态目录（首次运行时自动建）：\(dir)"])
        }
        lines.append("状态目录：\(dir)")
        switch LauncherConfig.load().warnings.isEmpty {
        case true: lines.append("registry/launchers 解析：无警告")
        case false:
            ok = false
            lines.append(contentsOf: LauncherConfig.load().warnings.prefix(6).map { "配置警告：" + $0 })
        }
        return (ok, lines)
    }

    private static func checkLaunchAgents() -> (ok: Bool, lines: [String]) {
        var lines: [String] = []
        var ok = true
        let uid = getuid()
        let items: [(String, String)] = [
            ("io.github.autugit.dockolate", "GUI 自启/崩溃拉起"),
            ("ai.local.model-hub", "中枢后台"),
        ]
        for (label, what) in items {
            let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
            if !FileManager.default.fileExists(atPath: plist) {
                lines.append("\(what)：缺 LaunchAgent（\(label).plist 不存在）")
                ok = false
                continue
            }
            // 只读查询：launchctl print 不属于被网关禁止的 bootstrap/submit
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["print", "gui/\(uid)/\(label)"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            lines.append("\(what)：\(p.terminationStatus == 0 ? "已加载" : "未加载（下次登录会自动加载，或在 Terminal 里 bootstrap）")")
            if p.terminationStatus != 0 { ok = false }
        }
        return (ok, lines)
    }

    /// hub-state.json 距今多少秒；文件缺失/格式坏返回 nil。
    /// `generated_at` 可能是 epoch 数（进程内）或 ISO8601 串（hub 写盘），两种都认。
    static func hubStateAgeSeconds() -> Double? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: SupportDir.hubState)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var ts: Double?
        if let n = obj["generated_at"] as? NSNumber { ts = n.doubleValue }
        if ts == nil, let str = obj["generated_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: str) { ts = date.timeIntervalSince1970 }
        }
        guard let stamp = ts else { return nil }
        return Date().timeIntervalSince1970 - stamp
    }

    private static func checkHub() -> (ok: Bool, detail: String) {
        guard let age = hubStateAgeSeconds() else {
            return (false, "没有可读的 hub-state.json（中枢没跑过；GUI 会自己兜底写状态）")
        }
        return (age < 30, String(format: "中枢状态 %.0f 秒前刷新（>30 秒算停摆）", age))
    }

    // MARK: - 对外

    /// `--doctor [--json]`
    static func run(asJSON: Bool = true) -> Int32 {
        var checks: [Check] = []
        let man = checkManifest()
        checks.append(Check(name: "bundle.manifest", ok: man.ok, detail: man.lines.joined(separator: "；")))
        let sig = checkSignature()
        checks.append(Check(name: "bundle.signature", ok: sig.ok, detail: sig.detail))
        let wr = checkBundleWritable()
        checks.append(Check(name: "bundle.location", ok: wr.ok, detail: wr.detail))
        let st = checkStateDir()
        checks.append(Check(name: "state", ok: st.ok, detail: st.lines.joined(separator: "；")))
        let la = checkLaunchAgents()
        checks.append(Check(name: "launchagents", ok: la.ok, detail: la.lines.joined(separator: "；")))
        let hub = checkHub()
        checks.append(Check(name: "hub", ok: hub.ok, detail: hub.detail))

        let allOK = checks.allSatisfy { $0.ok }
        if asJSON {
            let arr: [[String: Any]] = checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] }
            let obj: [String: Any] = [
                "ok": allOK,
                "bundle": bundlePath,
                "stateDir": SupportDir.dir,
                "checks": arr,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("bundle: \(bundlePath)")
            for c in checks { print((c.ok ? "✅ " : "❌ ") + c.name + "：" + c.detail) }
        }
        return allOK ? 0 : 1
    }

    /// GUI 启动时用：程序本体被动过就弹一次提示（开发用 DOCKOLATE_SKIP_MANIFEST=1 跳过）
    static func warnIfTampered() {
        let env = ProcessInfo.processInfo.environment
        if env["DOCKOLATE_SKIP_MANIFEST"] == "1" { return }
        if env["DOCKOLATE_SUPPORT_DIR"] != nil { return }      // 测试实例不打扰
        let (ok, lines) = checkManifest()
        guard !ok else { return }
        let alert = NSAlert()
        alert.messageText = "程序本体被改动过"
        alert.informativeText = lines.prefix(6).joined(separator: "\n")
            + "\n\n如果这是你刚重新编译的，忽略即可；否则请重跑 build.sh --install（或在 Terminal 里跑 tools/install-system.command）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
