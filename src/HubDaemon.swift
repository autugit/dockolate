// ============================================================
// 中枢后台（M0）
// ============================================================
//
// 设计分档见 projects/01_本机模型栈/docs/本地模型中枢_方案v2.md
//
// M0 只做两件事，刻意不做第三件：
//   ① 定期采样本机引擎/模型状态
//   ② 原子落一份 hub-state.json，供 GUI 与任何客户端读
//   ③ **不做**调度决策、**不碰**引擎进程
//
// 第 ③ 条是硬约束：daemon 挂了、重启了，正在跑的模型不受影响。
// 谁托管引擎进程，谁就不能是「可随时重启的东西」——这条在 M1 才引入，
// 届时引擎必须由 daemon 以 detach 方式拉起，不能做它的子进程。
//
// 状态文件路径在 ~/Library/Application Support/Dockolate/（本机私有），
// 代码里不出现端口/路径/型号等本机细节（本仓是公开仓）。

import Foundation

final class HubDaemon {
    static let supportDir = SupportDir.dir
    static let statePath = SupportDir.hubState
    static let lockPath = supportDir + "/hub.lock"
    static let registryPath = supportDir + "/registry.json"

    private let interval: TimeInterval
    private var seq = 0

    init(interval: TimeInterval = 5) {
        self.interval = max(1, interval)
    }

    // ---------- 单实例 ----------

    private static func acquireLock() -> Int32? {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    // ---------- 主循环 ----------

    func run() -> Never {
        guard let lock = Self.acquireLock() else {
            FileHandle.standardError.write(Data("hub: 已有实例在运行（\(Self.lockPath)）\n".utf8))
            exit(3)
        }
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }

        signal(SIGTERM) { _ in exit(0) }
        signal(SIGINT) { _ in exit(0) }

        let watcher = EngineWatcher()
        _ = watcher.refresh()
        Thread.sleep(forTimeInterval: 2.0)      // 首次采样差：CPU 活动要两次才有得比

        var lastError: String? = nil
        while true {
            // 长驻死循环里 Foundation 的临时对象不会自己释放：每轮包一层 autoreleasepool
            autoreleasepool {
            let runtime = watcher.refresh()
            do {
                let state = try buildState(runtime: runtime)
                try writeAtomically(state)
                lastError = nil
            } catch {
                // 采样失败不该让后台退出：写一条错误状态，下一轮重试
                lastError = String(describing: error)
                try? writeAtomically([
                    "schema": 1,
                    "generated_at": ISO8601DateFormatter().string(from: Date()),
                    "seq": seq,
                    "pid": Int(getpid()),
                    "error": lastError ?? "",
                ])
            }
            }
            seq += 1
            Thread.sleep(forTimeInterval: interval)
        }
    }

    // ---------- 采样 ----------

    private func buildState(runtime: ModelSnapshot) throws -> [String: Any] {
        let cfg = LauncherConfig.load()
        let policy = HubRegistry.load()

        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let enginesGB = runtime.rows.reduce(0.0) { $0 + $1.memGB }

        let engines: [[String: Any]] = runtime.rows.map { row in
            var d: [String: Any] = [
                "name": row.name,
                "state": row.state.text,
                "mem_gb": row.memGB,
                "engine": row.engine,
                "shared": row.shared,
            ]
            if let p = row.port { d["port"] = p }
            if let pid = row.pid { d["pid"] = Int(pid) }
            return d
        }

        // 只列「此刻在跑的」。完整权重清单由 GUI 写。
        // ⛔ 这里曾经跑 ModelInventory.scan()（每 5 秒全盘一遍）：daemon 常驻 RSS 涨到 GB 级、
        //    CPU 峰值 28%，而这份完整清单并没有任何外部消费者（网关只判引擎活跃）。
        let models: [[String: Any]] = runtime.rows.map { row in
            var d: [String: Any] = [
                "id": row.name,
                "title": row.name,
                "state": row.state.text,
                "mem_gb": row.memGB,
                "engine": row.engine,
            ]
            if let p = row.port { d["port"] = p }
            if let pid = row.pid { d["pid"] = Int(pid) }
            if let hit = policy.entry(for: row.name, recipe: nil) {
                d["policy"] = hit.jsonObject
            }
            return d
        }

        return [
            "schema": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "seq": seq,
            "pid": Int(getpid()),
            "interval_sec": interval,
            "models_source": "runtime-only",   // 不是完整清单：完整清单由 GUI 写
            "memory": [
                "total_gb": (totalGB * 10).rounded() / 10,
                "engines_gb": (enginesGB * 10).rounded() / 10,
                "reserve_gb": cfg.reserveGB,
            ],
            "engines": engines,
            "models": models,
            "registry": [
                "source": policy.source,
                "policies": policy.count,
            ],
        ]
    }

    /// GUI 内嵌写状态（取代常驻 --hub daemon）
    ///
    /// 为什么不让 daemon 常驻：它与 GUI 同一个 app bundle、同一个 bundle id，
    /// macOS 会认为「Dockolate 已经在运行」，点 Dock 图标时把事件交给那个无窗口的
    /// 后台进程 —— 表现就是「点图标打不开」。
    ///
    /// 这里只做序列化：entries / runtime 都是 GUI 已经算好的，**不扫盘**。
    static func writeStateFromGUI(entries: [CatalogEntry], runtime: ModelSnapshot,
                                  reserveGB: Double, seq: Int) {
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let enginesGB = runtime.rows.reduce(0.0) { $0 + $1.memGB }
        let policy = HubRegistry.load()

        let engines: [[String: Any]] = runtime.rows.map { row in
            var d: [String: Any] = [
                "name": row.name,
                "state": row.state.text,
                "mem_gb": row.memGB,
                "engine": row.engine,
                "shared": row.shared,
            ]
            if let p = row.port { d["port"] = p }
            if let pid = row.pid { d["pid"] = Int(pid) }
            return d
        }

        let models: [[String: Any]] = entries.map { e in
            var d: [String: Any] = [
                "id": e.id,
                "title": e.title,
                "state": e.state.text,
                "est_mem_gb": e.estMemGB,
                "disk_gb": e.diskGB,
                "can_launch": e.canLaunch,
                "can_stop": e.canStop,
            ]
            if let p = e.port { d["port"] = p }
            if let r = e.recipe?.id { d["recipe"] = r }
            if let hit = policy.entry(for: e.id, recipe: e.recipe?.id) {
                d["policy"] = hit.jsonObject
            }
            return d
        }

        let obj: [String: Any] = [
            "schema": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "seq": seq,
            "pid": Int(getpid()),
            "writer": "gui",
            "memory": [
                "total_gb": (totalGB * 10).rounded() / 10,
                "engines_gb": (enginesGB * 10).rounded() / 10,
                "reserve_gb": reserveGB,
            ],
            "engines": engines,
            "models": models,
            "registry": [
                "source": policy.source,
                "policies": policy.count,
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private func writeAtomically(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: Self.statePath), options: .atomic)
    }

    // ---------- 只读查询（供 CLI / GUI）----------

    static func printStatus() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            print("hub 状态文件不存在：\(statePath)")
            print("先启动后台：Dockolate --hub")
            exit(2)
        }
        // 顺带报一下「状态多旧」——GUI 退出后是否仍在刷新，靠这个判
        if let ts = obj["generated_at"] as? String,
           let date = ISO8601DateFormatter().date(from: ts) {
            let age = Date().timeIntervalSince(date)
            print("状态年龄：\(String(format: "%.1f", age)) s")
        }
        let out = try? JSONSerialization.data(withJSONObject: obj,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let out, let s = String(data: out, encoding: .utf8) { print(s) }
    }
}

// ============================================================
// 调度策略层（M0 只读：解析 + 报告，不执行）
// ============================================================
//
// 2026-10-29 合并：配方与策略只剩一份文件。
//   registry.json: recipes[]（怎么起：命令/端口/超时）
//                  models[]（调度策略：自启/驻留/重启/分组/互斥/对外 + 能力元数据）
//   launchers.json 降级为兼容回退：只在 registry 缺失或无 recipes 时读（见 LauncherConfig.load）。
// models[] 与 recipes[] 用 recipe 字段对齐。
//
// 「驻留」在这里的语义（用户 2026-10-29 澄清）：
//   resident  —— 拉起后**留在内存里，不主动卸载**（不自动释放、不被 LRU 回收）
//   自动重拉   —— 是另一个开关 restart_on_crash，**默认关**；本机当前全关

struct HubPolicyEntry {
    var id: String
    var aliases: [String] = []           // 兼容旧名（q27u / fn …），--ensure 也接受
    var autoStart: Bool = false          // daemon 启动时是否拉起
    var resident: Bool = true            // 拉起后是否保持内存驻留（默认保持）
    var restartOnCrash: Bool = false     // 崩溃后是否自动重拉（自回归，本机默认关）
    var group: String? = nil             // 同组共享内存预算、允许共存
    var mutexWith: [String] = []         // 与谁互斥
    var exposed: Bool = true             // 是否出现在对外模型列表
    var priority: Int = 0                // 抢占优先级（大者优先）
    var recipe: String? = nil            // 关联 launchers.json 的配方 id（清单条目靠它匹配）
    var contextWindow: Int? = nil
    var maxTokens: Int? = nil

    var jsonObject: [String: Any] {
        var d: [String: Any] = [
            "auto_start": autoStart,
            "resident": resident,
            "restart_on_crash": restartOnCrash,
            "mutex_with": mutexWith,
            "exposed": exposed,
            "priority": priority,
        ]
        if let g = group { d["group"] = g }
        if let c = contextWindow { d["context_window"] = c }
        if let m = maxTokens { d["max_tokens"] = m }
        return d
    }
}

struct HubRegistry {
    var source: String
    var entries: [String: HubPolicyEntry]

    var count: Int { entries.count }
    /// 把某个模型的策略写回 registry.json。
    /// 只改策略字段；aliases / capability / recipe 等原样保留。写前先备份。
    static func savePolicy(_ p: HubPolicyEntry) throws {
        let url = URL(fileURLWithPath: HubDaemon.registryPath)
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var models = root["models"] as? [[String: Any]] else {
            throw NSError(domain: "HubRegistry", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "registry.json 结构不认识（缺 models 数组）"])
        }
        guard let idx = models.firstIndex(where: { ($0["id"] as? String) == p.id }) else {
            throw NSError(domain: "HubRegistry", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "registry.json 里没有 id = \(p.id) 的条目"])
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let bak = url.path + ".bak.\(stamp)"
        try? FileManager.default.copyItem(atPath: url.path, toPath: bak)
        // 只留最近 10 份备份，否则每点一次保存就多一个文件
        let dir = (url.path as NSString).deletingLastPathComponent
        let base = (url.path as NSString).lastPathComponent + ".bak."
        if let olds = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            let baks = olds.filter { $0.hasPrefix(base) }.sorted(by: >).dropFirst(10)
            for b in baks { try? FileManager.default.removeItem(atPath: dir + "/" + b) }
        }

        var m = models[idx]
        m["auto_start"] = p.autoStart
        m["resident"] = p.resident
        m["restart_on_crash"] = p.restartOnCrash
        m["mutex_with"] = p.mutexWith
        m["exposed"] = p.exposed
        m["priority"] = p.priority
        if let g = p.group, !g.isEmpty { m["group"] = g } else { m.removeValue(forKey: "group") }
        if let c = p.contextWindow { m["context_window"] = c }
        if let t = p.maxTokens { m["max_tokens"] = t }
        models[idx] = m
        root["models"] = models

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    /// 匹配顺序：清单条目的 id 精确命中 → 清单条目的配方 id 命中 → 彼此后缀命中。
    /// 清单 id 常见形态是 "disk:<path>"，而策略条目用客户端模型名，所以配方关联最可靠。
    func entry(for id: String, recipe: String? = nil) -> HubPolicyEntry? {
        if let exact = entries[id] { return exact }
        if let r = recipe, let hit = entries.values.first(where: { $0.recipe == r }) { return hit }
        return entries.first { id.hasSuffix($0.key) || $0.key.hasSuffix(id) }?.value
    }

    static func load() -> HubRegistry {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: HubDaemon.registryPath)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            return HubRegistry(source: "absent", entries: [:])
        }
        var map: [String: HubPolicyEntry] = [:]
        for m in models {
            guard let id = m["id"] as? String else { continue }
            var e = HubPolicyEntry(id: id)
            if let v = m["aliases"] as? [String] { e.aliases = v }
            if let v = m["auto_start"] as? Bool { e.autoStart = v }
            if let v = m["resident"] as? Bool { e.resident = v }
            if let v = m["restart_on_crash"] as? Bool { e.restartOnCrash = v }
            if let v = m["exposed"] as? Bool { e.exposed = v }
            if let v = m["group"] as? String { e.group = v }
            if let v = m["mutex_with"] as? [String] { e.mutexWith = v }
            if let v = m["priority"] as? Int { e.priority = v }
            if let v = m["recipe"] as? String { e.recipe = v }
            if let v = m["context_window"] as? Int { e.contextWindow = v }
            if let v = m["max_tokens"] as? Int { e.maxTokens = v }
            map[id] = e
        }
        return HubRegistry(source: "registry.json", entries: map)
    }
}
