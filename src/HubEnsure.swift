// ============================================================
// 互斥前置检查（M1a）：我要用 X，现在能不能用
// ============================================================
//
// 用户令（2026-10-29）：**默认拒绝新请求**，弹窗提示用户，由用户手动选择是否切换。
// 不做任何「自动抢占」——抢占必须是人点了按钮才发生。
//
// 之所以是一次性 CLI（不是 daemon 内部逻辑）：
//   ① 弹窗会阻塞，不能卡住后台采样循环；
//   ② 调用方（网关 / 脚本 / harness）需要一个可判定的退出码。
//
// 退出码：
//   0  可用（已在跑 / 无冲突 / 用户选择切换并成功）
//   4  被占用：有互斥模型正在跑，且用户没有选择切换（默认拒绝）
//   5  无法判定（registry 里没有该模型 / 采样失败）
//   6  用户选择切换但切换失败
//
// 用法：
//   Dockolate --ensure=<模型名>              # 只判定，不弹窗（脚本/网关默认用这个）
//   Dockolate --ensure=<模型名> --ask        # 冲突时弹窗问用户要不要切换
//   Dockolate --ensure=<模型名> --switch     # 冲突时直接切（不弹窗；仅调试用）

import Foundation

enum HubEnsure {
    struct Outcome {
        var code: Int32
        var kind: String            // ok | busy | unknown | switched | failed
        var message: String
        var target: String
        var blockers: [String] = []
        var switchedFrom: [String] = []
        /// 目标此刻确实在运行（哪怕调用方探测端口失败）——网关据此避免误重启
        var alreadyRunning = false
    }

    /// 采样一次，返回「当前在跑」的清单条目
    private static func runningEntries(cfg: LauncherConfig) -> ([CatalogEntry], ModelSnapshot) {
        let watcher = EngineWatcher()
        _ = watcher.refresh()
        Thread.sleep(forTimeInterval: 1.2)          // 采样差
        let runtime = watcher.refresh()
        var invCfg = ModelInventory.Config()
        invCfg.extraDirs = cfg.extraScanRoots
        let inv = ModelInventory()
        inv.engineDirs = runtime.modelDirs
        let units = inv.scan(config: invCfg)
        let roots = (invCfg.includeDefaults ? ModelInventory.defaultRoots().map { $0.path } : [])
            + invCfg.extraDirs + runtime.modelDirs
        let entries = ModelCatalog.build(units: units, runtime: runtime, config: cfg,
                                         observed: ObservedMemory(), roots: roots)
        // 2026-11-06：把「挂载待机」（.idle = 模型已加载、占着内存但没在解码）也算进来。
        // 旧实现只认 .running / .loading，于是一个占着几十 GB 的模型挂着待机时，中枢对「拉起
        // 另一个重模型」仍旧答「与在跑的模型不互斥」——那个模型的启动脚本并不会替别人腾内存，
        // 真叠上去就把机器压爆。界面各处一直是三态一起算，这里对齐。
        return (entries.filter { [.running, .idle, .loading].contains($0.state) }, runtime)
    }

    /// 该清单条目对应哪条策略：先按 recipe 对齐，再按标题/运行时名做宽松匹配
    private static func policy(for entry: CatalogEntry, reg: HubRegistry) -> HubPolicyEntry? {
        if let r = entry.recipe?.id, let hit = reg.entries.values.first(where: { $0.recipe == r }) {
            return hit
        }
        let hay = (entry.title + " " + entry.runtimeName).lowercased()
        return reg.entries.values.first { p in
            hay.contains(p.id.lowercased()) || p.aliases.contains { hay.contains($0.lowercased()) }
        }
    }

    /// 一次性 CLI 入口：判定 → 按需打印 JSON / 纯文本 → 返回退出码。
    static func run(target: String, ask: Bool, forceSwitch: Bool, asJSON: Bool) -> Int32 {
        emit(decide(target: target, ask: ask, forceSwitch: forceSwitch), asJSON)
    }

    static func decide(target: String, ask: Bool, forceSwitch: Bool) -> Outcome {
        let cfg = LauncherConfig.load()
        let reg = HubRegistry.load()

        // 1. 目标必须能在 registry 里找到
        guard let targetPolicy = reg.entries.values.first(where: { p in
            p.id == target || p.aliases.contains(target)
        }) else {
            let known = reg.entries.keys.sorted().joined(separator: ", ")
            return Outcome(code: 5, kind: "unknown",
                           message: "registry 里没有模型「\(target)」。已知：\(known)",
                           target: target)
        }

        let (running, _) = runningEntries(cfg: cfg)
        // 2. 目标已经在跑 → 直接用
        if let me = running.first(where: { e in
            if let r = e.recipe?.id, r == targetPolicy.recipe { return true }
            let hay = (e.title + " " + e.runtimeName).lowercased()
            return hay.contains(targetPolicy.id.lowercased())
        }) {
            return Outcome(code: 0, kind: "ok",
                           message: "「\(targetPolicy.id)」已在运行（pid \(me.pid ?? 0)）",
                           target: targetPolicy.id, alreadyRunning: true)
        }

        // 3. 找互斥冲突：双向判断（对方的 mutex_with 里点名我，也算冲突）
        var blockers: [(CatalogEntry, HubPolicyEntry)] = []
        for e in running {
            guard let p = policy(for: e, reg: reg) else { continue }
            if targetPolicy.mutexWith.contains(p.id) || p.mutexWith.contains(targetPolicy.id) {
                blockers.append((e, p))
            }
        }

        // 3b) 未登记占用（2026-10-31 事故的直接教训）：端口在听，但监听进程不是任何已登记配方的引擎。
        //     旧实现在这里直接答「不互斥，可按需拉起」——于是 mlx_lm.server 冒充的 27B 旁边又起了一个。
        //     先报「有未登记占用」，再谈互斥。
        let stray = unregisteredOccupancy(cfg: cfg, running: running)
        if !stray.isEmpty {
            return Outcome(code: 7, kind: "unregistered",
                           message: "有未登记引擎在跑：" + stray.joined(separator: "；")
                                       + "。先用 --release 收掉，或把它登记进 registry.json",
                           target: targetPolicy.id)
        }

        guard !blockers.isEmpty else {
            return Outcome(code: 0, kind: "ok",
                           message: "「\(targetPolicy.id)」与在跑的模型不互斥，可按需拉起",
                           target: targetPolicy.id)
        }

        let names = blockers.map { "\($0.1.id)（端口 \($0.0.port.map(String.init) ?? "?")）" }
        let busyMsg = "「\(targetPolicy.id)」与正在运行的 " + names.joined(separator: "、") + " 互斥"

        // 4a. 不要求切换 → 默认拒绝，把占用者报清楚
        if !ask && !forceSwitch {
            return Outcome(code: 4, kind: "busy", message: busyMsg + "；默认不抢占",
                           target: targetPolicy.id, blockers: blockers.map { $0.1.id })
        }

        // 4b. 问人（或强制切）
        if ask && !forceSwitch {
            let ok = askUser(title: "本地模型互斥",
                             text: busyMsg + "。\n\n要停掉它并切换到「\(targetPolicy.id)」吗？")
            if !ok {
                return Outcome(code: 4, kind: "busy", message: busyMsg + "；用户选择不切换",
                               target: targetPolicy.id, blockers: blockers.map { $0.1.id })
            }
        }

        // 5. 执行切换：先停占用者 → 等内存真的还回来（M1b）→ 再拉起目标
        guard let targetEntry = entriesByRecipe(targetPolicy.recipe, cfg: cfg) else {
            return Outcome(code: 5, kind: "unknown",
                           message: "找不到「\(targetPolicy.id)」对应的清单条目（recipe \(targetPolicy.recipe ?? "?")）",
                           target: targetPolicy.id)
        }
        let baseline = ReleaseGate.availableGB(reserveGB: cfg.reserveGB)
        let runner = ModelActionRunner()
        var stopped: [String] = []
        for (entry, pol) in blockers {
            runner.stop(entry)
            waitIdle(runner, id: entry.id)
            stopped.append(pol.id)
        }
        // 停完 ≠ 内存回来：等可用内存够 target.estMemGB + 预留，超时就不起（否则两个叠在残骸上）
        let gate = ReleaseGate.waitMemory(atLeast: targetEntry.estMemGB + cfg.reserveGB,
                                          expectGB: targetEntry.estMemGB,
                                          baselineGB: baseline,
                                          reserveGB: cfg.reserveGB,
                                          timeout: 120)
        guard gate.ok else {
            return Outcome(code: 6, kind: "failed",
                           message: "已停止 " + stopped.joined(separator: "、")
                                       + "，但内存没还回来：" + gate.detail
                                       + "；为免两个模型叠在残骸上，未拉起「\(targetPolicy.id)」",
                           target: targetPolicy.id, switchedFrom: stopped)
        }
        runner.launch(targetEntry)
        let launched = waitIdle(runner, id: targetEntry.id)
        if launched {
            return Outcome(code: 0, kind: "switched",
                           message: "已停止 " + stopped.joined(separator: "、") + "，并拉起「\(targetPolicy.id)」",
                           target: targetPolicy.id, switchedFrom: stopped)
        }
        let detail = runner.state(for: targetEntry.id)?.detail ?? "未知原因"
        return Outcome(code: 6, kind: "failed",
                       message: "已停止 " + stopped.joined(separator: "、") + "，但拉起「\(targetPolicy.id)」失败：\(detail)",
                       target: targetPolicy.id, switchedFrom: stopped)
    }

    // ---------- 只卸：停 + 等内存真的还回来（M1b） ----------

    /// `--release=<模型>`：把模型停掉并等到内存回收；不做拉起。
    static func release(target: String, asJSON: Bool = false) -> Int32 {
        let cfg = LauncherConfig.load()
        let reg = HubRegistry.load()
        guard let pol = reg.entries.values.first(where: { $0.id == target || $0.aliases.contains(target) }) else {
            return emit(Outcome(code: 5, kind: "unknown",
                                message: "registry 里没有模型「\(target)」", target: target), asJSON)
        }
        let (running, _) = runningEntries(cfg: cfg)
        guard let me = running.first(where: { e in
            if let r = e.recipe?.id, r == pol.recipe { return true }
            let hay = (e.title + " " + e.runtimeName).lowercased()
            return hay.contains(pol.id.lowercased())
        }) else {
            return emit(Outcome(code: 0, kind: "ok",
                                message: "「\(pol.id)」本来就没在跑", target: pol.id), asJSON)
        }
        let baseline = ReleaseGate.availableGB(reserveGB: cfg.reserveGB)
        let runner = ModelActionRunner()
        runner.stop(me)
        _ = waitIdle(runner, id: me.id, timeout: 180)
        let after = ReleaseGate.availableGB(reserveGB: cfg.reserveGB)
        return emit(Outcome(code: 0, kind: "released",
                            message: String(format: "「%@」已卸载；回收 %.1f GB（可用 %.1f → %.1f GB）",
                                            pol.id, max(0, after - baseline), baseline, after),
                            target: pol.id), asJSON)
    }

    // ---------- 未登记占用 ----------

    /// 端口在听、但监听进程的 argv 里没有该端口配方的引擎关键字 ⇒ 未登记。
    private static func unregisteredOccupancy(cfg: LauncherConfig, running: [CatalogEntry]) -> [String] {
        var out: [String] = []
        for r in cfg.recipes where r.kind != "service" {
            guard let port = r.port else { continue }
            for pid in ReleaseGate.listenerPids(port) {
                let cmd = commandLine(pid)
                if engineMatches(r.engine, cmd: cmd) { continue }
                if running.contains(where: { $0.port == port && $0.pid == pid }) { continue }
                out.append("端口 \(port) pid \(pid)：\(cmd.prefix(90))")
            }
        }
        return out
    }

    private static func commandLine(_ pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 引擎显示名 → argv 关键字。不认识的名字返回 true（宁可不误报）。
    private static func engineMatches(_ engine: String?, cmd: String) -> Bool {
        guard let e = engine?.lowercased(), !e.isEmpty else { return true }
        let hay = cmd.lowercased()
        let keys: [String]
        switch true {
        case e.contains("splash"): keys = ["splash"]
        case e.contains("strata"): keys = ["strata"]
        case e.contains("omlx"): keys = ["omlx"]
        case e.contains("llama"): keys = ["llama-server", "llama.cpp", "llama-cli"]
        case e.contains("mlx-serve"), e.contains("mlxserve"): keys = ["mlx-serve"]
        case e.contains("comfy"): keys = ["main.py", "comfy"]
        case e.contains("mlx_lm"), e.contains("mlx-lm"): keys = ["mlx_lm"]
        default: return true
        }
        return keys.contains { hay.contains($0) }
    }

    // ---------- 辅助 ----------

    private static func entriesByRecipe(_ recipe: String?, cfg: LauncherConfig) -> CatalogEntry? {
        guard let rid = recipe else { return nil }
        let (entries, _) = runningEntries(cfg: cfg)
        if let hit = entries.first(where: { $0.recipe?.id == rid }) { return hit }
        // 没在跑的条目不会出现在 running 里，重扫一次取全量
        let watcher = EngineWatcher()
        let runtime = watcher.refresh()
        var invCfg = ModelInventory.Config()
        invCfg.extraDirs = cfg.extraScanRoots
        let inv = ModelInventory()
        inv.engineDirs = runtime.modelDirs
        let units = inv.scan(config: invCfg)
        let roots = (invCfg.includeDefaults ? ModelInventory.defaultRoots().map { $0.path } : [])
            + invCfg.extraDirs + runtime.modelDirs
        let all = ModelCatalog.build(units: units, runtime: runtime, config: cfg,
                                     observed: ObservedMemory(), roots: roots)
        return all.first { $0.recipe?.id == rid }
    }

    /// 等某个条目的动作结束；返回是否「正常结束」（不是 failed）
    @discardableResult
    private static func waitIdle(_ runner: ModelActionRunner, id: String, timeout: TimeInterval = 300) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let st = runner.state(for: id) else { continue }
            if !st.phase.isBusy, st.finishedAt != nil {
                if case .failed = st.phase { return false }
                return true
            }
        }
        return false
    }

    /// 用 osascript 弹一个带「切换 / 取消」的对话框；超时或非交互环境返回 false
    private static func askUser(title: String, text: String, timeoutSec: Int = 90) -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        display dialog "\(escaped)" buttons {"取消", "切换"} default button "取消" \
        with title "\(title)" with icon caution giving up after \(timeoutSec)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.contains("button returned:切换")
    }

    private static func emit(_ o: Outcome, _ asJSON: Bool) -> Int32 {
        if asJSON {
            var d: [String: Any] = ["code": Int(o.code), "kind": o.kind,
                                    "message": o.message, "target": o.target]
            if !o.blockers.isEmpty { d["blockers"] = o.blockers }
            if !o.switchedFrom.isEmpty { d["switched_from"] = o.switchedFrom }
            if o.alreadyRunning { d["already_running"] = true }
            if let data = try? JSONSerialization.data(withJSONObject: d,
                                                      options: [.sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        } else {
            FileHandle.standardError.write(Data((o.message + "\n").utf8))
        }
        return o.code
    }
}
