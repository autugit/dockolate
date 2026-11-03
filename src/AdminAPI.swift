// ============================================================
// 管理 API（给「用户的 AI」用的稳定命令行契约）
// ============================================================
//
// 设计原则：
//   · **一次调用一个 JSON 请求，一行 JSON 回答**：`Dockolate --api '{"op":"…"}'`
//   · 不依赖 GUI 是否在跑；不碰程序本体，只读写 `SupportDir` 里的状态文件
//   · 所有写操作都是「读原始 JSON → 改字段 → 原子写回」，⛔ 不经过解析模型回写，
//     否则未识别的字段会被悄悄丢掉（升级中途丢配方是最贵的 bug）
//   · 出错也是 JSON：{ok:false, code:"invalid|notfound|busy|io", message, …}
//
// 退出码：0 成功｜2 用法/请求格式错｜3 找不到｜4 校验失败｜5 冲突（端口占用/正在跑）
//
// 详见 docs/CLI_API.md。

import Foundation

/// 轻量结果类型：仓库里其它地方也用 Result，但这里失败信息就是给人/AI 看的字符串，
/// 不想为它引入 Error 包装。用私有枚举最省事。
private enum Res<T> {
    case ok(T)
    case err(String)
}

enum AdminAPI {

    // MARK: - 输出

    private static func emit(_ obj: [String: Any], code: Int32 = 0) -> Int32 {
        var o = obj
        if o["ok"] == nil { o["ok"] = (code == 0) }
        let data = (try? JSONSerialization.data(withJSONObject: o,
                                                options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return code
    }

    private static func fail(_ message: String, code: String = "invalid", exit: Int32 = 4,
                             extra: [String: Any] = [:]) -> Int32 {
        var o: [String: Any] = ["ok": false, "code": code, "message": message]
        for (k, v) in extra { o[k] = v }
        return emit(o, code: exit)
    }

    // MARK: - 入口

    /// `--api <json|@file|->`
    static func run(arguments: [String]) -> Int32 {
        guard let raw = arguments.first(where: { $0.hasPrefix("--api=") || $0 == "--api" }) else {
            return fail("缺少 --api 参数", code: "usage", exit: 2)
        }
        var payload: String
        if raw.hasPrefix("--api=") {
            payload = String(raw.dropFirst("--api=".count))
        } else {
            let idx = arguments.firstIndex(of: raw)!
            guard arguments.count > idx + 1 else { return fail("--api 后面要跟 JSON 或 @文件", code: "usage", exit: 2) }
            payload = arguments[idx + 1]
        }
        if payload == "-" {
            let d = FileHandle.standardInput.readDataToEndOfFile()
            payload = String(data: d, encoding: .utf8) ?? ""
        } else if payload.hasPrefix("@") {
            let p = (String(payload.dropFirst()) as NSString).expandingTildeInPath
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
                  let s = String(data: d, encoding: .utf8) else {
                return fail("读不了请求文件：\(p)", code: "io", exit: 2)
            }
            payload = s
        }
        guard let data = payload.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fail("请求不是合法 JSON 对象", code: "usage", exit: 2)
        }
        return handle(req)
    }

    private static func handle(_ req: [String: Any]) -> Int32 {
        guard let op = (req["op"] as? String)?.lowercased(), !op.isEmpty else {
            return fail("缺少 op", code: "usage", exit: 2)
        }
        switch op {
        case "help":                    return help()
        case "status":                  return status()
        case "model.list":              return modelList(req)
        case "model.get":               return modelGet(req)
        case "model.add":               return modelAdd(req)
        case "model.update":            return modelUpdate(req)
        case "model.remove":            return modelRemove(req)
        case "model.launch":            return modelLaunch(req)
        case "model.stop":              return modelStop(req)
        case "config.get":              return configGet()
        case "config.set":              return configSet(req)
        case "workgroup.list":          return workgroupList()
        case "workgroup.add":           return workgroupAdd(req)
        case "workgroup.remove":        return workgroupRemove(req)
        case "doctor":                  return Doctor.run(asJSON: true)
        default:
            return fail("未知 op：\(op)（用 op=help 看清单）", code: "usage", exit: 2)
        }
    }

    private static func help() -> Int32 {
        let ops = [
            "status", "model.list", "model.get", "model.add", "model.update", "model.remove",
            "model.launch", "model.stop", "config.get", "config.set",
            "workgroup.list", "workgroup.add", "workgroup.remove", "doctor",
        ]
        return emit([
            "ok": true,
            "usage": "Dockolate --api '<json>'   （也支持 --api @file.json / --api - 从 stdin 读）",
            "ops": ops,
            "docs": "docs/CLI_API.md",
            "state_dir": SupportDir.dir,
        ])
    }

    // MARK: - registry.json 原始读写

    private static func readRegistry() -> Res<[String: Any]> {
        let path = SupportDir.registry
        guard FileManager.default.fileExists(atPath: path) else {
            return .ok(["reserveGB": 6.0, "scanDirs": [String](), "recipes": [[String: Any]]()])
        }
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .err("读不了 \(path)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return .err("\(path) 不是合法 JSON 对象——拒绝改动（请先修复或从 .bak 恢复）")
        }
        return .ok(obj)
    }

    private static func writeRegistry(_ root: [String: Any]) -> Res<Bool> {
        SupportDir.ensure()
        guard let d = try? JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys]) else {
            return .err("序列化失败")
        }
        // 每次写前留一份 .bak（用户/AI 改坏时可回滚）；只保留最近 5 份
        let path = SupportDir.registry
        if FileManager.default.fileExists(atPath: path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak." + stamp)
            pruneBackups(for: path, keep: 5)
        }
        do {
            try d.write(to: URL(fileURLWithPath: path), options: .atomic)
            return .ok(true)
        } catch {
            return .err("写不了 \(path)：\(error.localizedDescription)")
        }
    }

    private static func pruneBackups(for path: String, keep: Int) {
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent + ".bak."
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let baks = items.filter { $0.hasPrefix(base) }.sorted()
        for old in baks.dropLast(keep) {
            try? FileManager.default.removeItem(atPath: dir + "/" + old)
        }
    }

    private static func recipes(_ root: [String: Any]) -> [[String: Any]] {
        (root["recipes"] as? [[String: Any]]) ?? []
    }

    /// 把 recipe 翻成对外的一致形状（不给用户看内部未识别的键，但保留原始键用于回写）
    private static func publicRecipe(_ r: [String: Any]) -> [String: Any] {
        var o: [String: Any] = [:]
        for k in ["id", "title", "engine", "path", "port", "category", "estMemGB",
                  "start", "stop", "log", "metrics", "media", "readyTimeoutSec", "kind"] {
            if let v = r[k] { o[k] = v }
        }
        if let port = (r["port"] as? NSNumber)?.intValue {
            o["running"] = !ReleaseGate.listenerPids(port).isEmpty
            if let pid = ReleaseGate.listenerPids(port).first {
                o["pid"] = Int(pid)
                if let rss = MemoryPoolBar.subtreeRSSGiB(rootPid: pid) { o["rssGB"] = (rss * 100).rounded() / 100 }
            }
        } else {
            o["running"] = false
        }
        return o
    }

    // MARK: - status / model.list

    private static func status() -> Int32 {
        let cfg = LauncherConfig.load()
        var used = 0.0, total = 0.0
        let s = MemorySampler()
        let r = s.next()
        used = r.usedGB; total = r.totalGB
        let reg = HubRegistry.load()
        let hubAge = Doctor.hubStateAgeSeconds()
        var running: [[String: Any]] = []
        for r in cfg.recipes {
            guard let port = r.port else { continue }
            let pids = ReleaseGate.listenerPids(port)
            guard let pid = pids.first else { continue }
            var row: [String: Any] = ["id": r.id, "title": r.title ?? r.id, "port": port, "pid": Int(pid)]
            if let rss = MemoryPoolBar.subtreeRSSGiB(rootPid: pid) { row["rssGB"] = (rss * 100).rounded() / 100 }
            running.append(row)
        }
        return emit([
            "ok": true,
            "memory": ["totalGB": total, "usedGB": used,
                       "reserveGB": cfg.reserveGB, "freeGB": max(0, total - used - cfg.reserveGB)],
            "recipes": cfg.recipes.count,
            "running": running,
            "hub": ["stateAgeSec": hubAge ?? -1, "policies": reg.entries.count],
            "stateDir": SupportDir.dir,
        ])
    }

    private static func modelList(_ req: [String: Any]) -> Int32 {
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(let root):
            var list = recipes(root).map { publicRecipe($0) }
            if let cat = req["category"] as? String, !cat.isEmpty {
                list = list.filter { (($0["category"] as? String) ?? "") == cat }
            }
            list.sort { ((($0["title"] as? String) ?? "")) .localizedCompare((($1["title"] as? String) ?? "")) == .orderedAscending }
            return emit(["ok": true, "count": list.count, "models": list])
        }
    }

    private static func modelGet(_ req: [String: Any]) -> Int32 {
        guard let id = req["id"] as? String else { return fail("缺少 id", code: "usage", exit: 2) }
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(let root):
            guard let r = recipes(root).first(where: { ($0["id"] as? String) == id }) else {
                return fail("没有这个 id：\(id)", code: "notfound", exit: 3)
            }
            return emit(["ok": true, "model": publicRecipe(r)])
        }
    }

    // MARK: - 校验

    private static let knownCategories: Set<String> = [
        "chat", "image", "video", "audio", "embedding", "service", "part",
    ]

    /// 校验一份「要写进 registry 的 recipe」，返回 (规整后的对象, 警告) 或错误信息。
    /// 只拒绝**会让中枢起错东西**的问题；其余（路径暂不存在等）只给警告。
    private static func validate(_ inObj: [String: Any], existing: [[String: Any]],
                                 allowIdCollision: String?) -> Res<([String: Any], [String])> {
        var r = inObj
        guard let id = (r["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            return .err("缺 id")
        }
        let legal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard id.unicodeScalars.allSatisfy({ legal.contains($0) }), id.count <= 64 else {
            return .err("id 只允许字母/数字/._-，长度 ≤64：\(id)")
        }
        r["id"] = id
        guard let title = (r["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return .err("缺 title")
        }
        r["title"] = title

        var warnings: [String] = []

        if let n = r["port"] {
            guard let num = n as? NSNumber, (1...65535).contains(num.intValue) else {
                return .err("port 必须是 1…65535 的整数")
            }
            let port = num.intValue
            r["port"] = port
            for other in existing {
                guard let oid = other["id"] as? String, oid != allowIdCollision else { continue }
                if let op = (other["port"] as? NSNumber)?.intValue, op == port {
                    return .err("端口 \(port) 已被配方「\(oid)」占用")
                }
            }
        }

        if let v = r["start"] {
            guard CommandSpec.decode(v) != nil else { return .err("start 必须是非空字符串或非空 argv 数组") }
        } else if (r["kind"] as? String) == "service" {
            warnings.append("kind=service 但没有 start：只能识别、不能拉起")
        } else {
            return .err("缺 start（拉起命令）；确实不想让它可拉起就传 kind=service")
        }

        if let v = r["stop"], CommandSpec.decode(v) == nil {
            return .err("stop 必须是非空字符串或非空 argv 数组（或省略）")
        }

        if let p = r["path"] as? String, !p.isEmpty {
            let expanded = (p as NSString).expandingTildeInPath
            r["path"] = expanded
            if !FileManager.default.fileExists(atPath: expanded) {
                warnings.append("path 现在不存在（可以稍后再下载）：\(expanded)")
            }
        }

        if let e = r["estMemGB"] {
            guard let n = e as? NSNumber, n.doubleValue > 0, n.doubleValue < 4096 else {
                return .err("estMemGB 必须是 (0,4096) 的数")
            }
        }

        if let c = r["category"] as? String, !c.isEmpty, !knownCategories.contains(c.lowercased()) {
            warnings.append("category「\(c)」不在已知类别里（\(knownCategories.sorted().joined(separator: "/"))），界面会归到「其他」")
        }

        if let k = r["kind"] as? String, !["model", "service"].contains(k) {
            warnings.append("kind「\(k)」不认识，按 model 处理")
            r["kind"] = "model"
        }

        for key in ["metrics", "media"] {
            if let v = r[key] as? String, !v.isEmpty {
                let allowed = key == "media" ? ["comfyui", "mlxserve"] : ["text", "comfyui", "mlxserve"]
                if !allowed.contains(v.lowercased()) {
                    warnings.append("\(key)「\(v)」不认识（可选：\(allowed.joined(separator: "/"))）")
                }
            }
        }
        return .ok((r, warnings))
    }

    // MARK: - model.add / update / remove

    private static func modelAdd(_ req: [String: Any]) -> Int32 {
        guard var obj = req["model"] as? [String: Any] else {
            return fail("缺少 model 对象", code: "usage", exit: 2)
        }
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(var root):
            let existing = recipes(root)
            if let id = obj["id"] as? String, existing.contains(where: { ($0["id"] as? String) == id }) {
                return fail("id 已存在：\(id)（要改请用 model.update）", code: "conflict", exit: 5)
            }
            if obj["id"] == nil {
                obj["id"] = "m-" + UUID().uuidString.prefix(8).lowercased()
            }
            switch validate(obj, existing: existing, allowIdCollision: nil) {
            case .err(let m): return fail(m)
            case .ok(let (clean, warnings)):
                var list = existing
                list.append(clean)
                root["recipes"] = list
                switch writeRegistry(root) {
                case .err(let m): return fail(m, code: "io")
                case .ok:
                    return emit(["ok": true, "id": clean["id"] ?? "", "warnings": warnings,
                                 "count": list.count, "path": SupportDir.registry])
                }
            }
        }
    }

    private static func modelUpdate(_ req: [String: Any]) -> Int32 {
        guard let id = req["id"] as? String else { return fail("缺少 id", code: "usage", exit: 2) }
        guard let patch = req["patch"] as? [String: Any], !patch.isEmpty else {
            return fail("缺少 patch（要改的字段）", code: "usage", exit: 2)
        }
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(var root):
            var list = recipes(root)
            guard let idx = list.firstIndex(where: { ($0["id"] as? String) == id }) else {
                return fail("没有这个 id：\(id)", code: "notfound", exit: 3)
            }
            if let newId = patch["id"] as? String, newId != id {
                return fail("不支持改 id（会打断记录/政策引用）；要改名请删了重加")
            }
            var merged = list[idx]
            for (k, v) in patch { merged[k] = v }
            switch validate(merged, existing: list, allowIdCollision: id) {
            case .err(let m): return fail(m)
            case .ok(let (clean, warnings)):
                list[idx] = clean
                root["recipes"] = list
                switch writeRegistry(root) {
                case .err(let m): return fail(m, code: "io")
                case .ok:
                    return emit(["ok": true, "id": id, "warnings": warnings, "path": SupportDir.registry])
                }
            }
        }
    }

    private static func modelRemove(_ req: [String: Any]) -> Int32 {
        guard let id = req["id"] as? String else { return fail("缺少 id", code: "usage", exit: 2) }
        let stopFirst = (req["stop"] as? Bool) ?? false
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(var root):
            var list = recipes(root)
            guard let idx = list.firstIndex(where: { ($0["id"] as? String) == id }) else {
                return fail("没有这个 id：\(id)", code: "notfound", exit: 3)
            }
            let recipe = list[idx]
            if let port = (recipe["port"] as? NSNumber)?.intValue {
                let pids = ReleaseGate.listenerPids(port)
                if !pids.isEmpty {
                    guard stopFirst else {
                        return fail("「\(id)」正在端口 \(port) 上运行（pid \(pids.map(String.init).joined(separator: ","))）；要一起停请加 stop:true",
                                    code: "busy", exit: 5)
                    }
                    let rc = runStop(recipe: recipe, port: port, force: true)
                    if rc != 0 { return fail("停止失败，未删除配方", code: "busy", exit: 5) }
                }
            }
            list.remove(at: idx)
            root["recipes"] = list
            switch writeRegistry(root) {
            case .err(let m): return fail(m, code: "io")
            case .ok:
                return emit(["ok": true, "id": id, "count": list.count,
                             "note": "只删了配方，权重文件没动", "path": SupportDir.registry])
            }
        }
    }

    // MARK: - launch / stop

    /// 跑一条 CommandSpec；返回 (退出码, 输出尾巴)
    private static func runCommand(_ spec: CommandSpec, timeout: Double = 60) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.argv[0])
        p.arguments = Array(spec.argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "起不来：\(error.localizedDescription)") }
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        let tail = String(data: d, encoding: .utf8) ?? ""
        return (p.terminationStatus, String(tail.suffix(400)))
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func modelLaunch(_ req: [String: Any]) -> Int32 {
        guard let id = req["id"] as? String else { return fail("缺少 id", code: "usage", exit: 2) }
        let wait = (req["wait"] as? Bool) ?? true
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(let root):
            guard let recipe = recipes(root).first(where: { ($0["id"] as? String) == id }) else {
                return fail("没有这个 id：\(id)", code: "notfound", exit: 3)
            }
            let port = (recipe["port"] as? NSNumber)?.intValue
            if let port = port, !ReleaseGate.listenerPids(port).isEmpty {
                return emit(["ok": true, "id": id, "alreadyRunning": true, "pid": Int(ReleaseGate.listenerPids(port)[0])])
            }
            guard let startAny = recipe["start"], let spec = CommandSpec.decode(startAny) else {
                return fail("这条配方没有 start，没法拉起", code: "invalid")
            }
            let cfg = LauncherConfig.load()
            let force = (req["force"] as? Bool) ?? false
            // 内存预检：可用内存不够时不硬上（与 GUI 的 ensure 同一口径）；force:true 跳过
            let avail = ReleaseGate.availableGB(reserveGB: cfg.reserveGB)
            if !force, let est = (recipe["estMemGB"] as? NSNumber)?.doubleValue, est > 0, est > avail + 0.5 {
                return fail(String(format: "可用内存 %.1f GB < 估算 %.1f GB，未拉起（可先卸别的模型，或传 force:true）",
                                   avail, est), code: "busy", exit: 5)
            }
            let logPath = (recipe["log"] as? String)
                ?? (NSHomeDirectory() + "/Library/Logs/Dockolate/" + id + ".log")
            try? FileManager.default.createDirectory(
                atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let line: String
            if spec.isShell {
                line = spec.argv[2] + " >> " + shellQuote(logPath) + " 2>&1 & echo $!"
            } else {
                let cmd = spec.argv.map(shellQuote).joined(separator: " ")
                line = cmd + " >> " + shellQuote(logPath) + " 2>&1 & echo $!"
            }
            let (rc, out) = runCommand(CommandSpec(argv: ["/bin/sh", "-c", line], isShell: false))
            let pid = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            guard rc == 0, pid > 0 else { return fail("启动命令失败：\(out)", code: "io") }
            var result: [String: Any] = ["ok": true, "id": id, "pid": Int(pid), "log": logPath]
            if wait, let port = port {
                let deadline = Date().addingTimeInterval((recipe["readyTimeoutSec"] as? NSNumber)?.doubleValue ?? 180)
                while Date() < deadline {
                    if !ReleaseGate.listenerPids(port).isEmpty { result["ready"] = true; break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if result["ready"] == nil { result["ready"] = false; result["note"] = "超时未见端口 \(port) 监听，看日志" }
            }
            return emit(result)
        }
    }

    private static func modelStop(_ req: [String: Any]) -> Int32 {
        guard let id = req["id"] as? String else { return fail("缺少 id", code: "usage", exit: 2) }
        let force = (req["force"] as? Bool) ?? false
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(let root):
            guard let recipe = recipes(root).first(where: { ($0["id"] as? String) == id }) else {
                return fail("没有这个 id：\(id)", code: "notfound", exit: 3)
            }
            let port = (recipe["port"] as? NSNumber)?.intValue ?? 0
            let rc = runStop(recipe: recipe, port: port, force: force)
            if rc == 0 {
                return emit(["ok": true, "id": id, "stopped": true])
            } else if rc == 2 {
                return fail("「\(id)」没有 stop 命令；要强杀请加 force:true", code: "busy", exit: 5)
            }
            return fail("停止失败（见日志/进程）", code: "io")
        }
    }

    /// 0 成功｜2 没配方也没 force｜3 失败
    private static func runStop(recipe: [String: Any], port: Int, force: Bool) -> Int32 {
        if let stopAny = recipe["stop"], let spec = CommandSpec.decode(stopAny) {
            let (rc, _) = runCommand(spec, timeout: 120)
            if rc != 0 { return 3 }
        } else if !force {
            return 2
        }
        guard port > 0 else { return 0 }
        // 等端口真的释放（最多 10 s），force 时再动手
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if ReleaseGate.listenerPids(port).isEmpty { return 0 }
            Thread.sleep(forTimeInterval: 0.3)
        }
        if force {
            for pid in ReleaseGate.listenerPids(port) { kill(pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 2)
            for pid in ReleaseGate.listenerPids(port) { kill(pid, SIGKILL) }
            let d2 = Date().addingTimeInterval(5)
            while Date() < d2 {
                if ReleaseGate.listenerPids(port).isEmpty { return 0 }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return 3
    }

    // MARK: - config

    private static func configGet() -> Int32 {
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(let root):
            var out: [String: Any] = [:]
            out["reserveGB"] = (root["reserveGB"] as? NSNumber)?.doubleValue ?? 6
            out["scanDirs"] = (root["scanDirs"] as? [String]) ?? [String]()
            out["stateDir"] = SupportDir.dir
            out["registry"] = SupportDir.registry
            return emit(["ok": true, "config": out])
        }
    }

    private static func configSet(_ req: [String: Any]) -> Int32 {
        guard let patch = req["config"] as? [String: Any], !patch.isEmpty else {
            return fail("缺少 config 对象", code: "usage", exit: 2)
        }
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(var root):
            if let r = patch["reserveGB"] {
                guard let n = r as? NSNumber, n.doubleValue >= 0, n.doubleValue < 4096 else {
                    return fail("reserveGB 必须是非负数（GB）")
                }
                root["reserveGB"] = n.doubleValue
            }
            if let dirs = patch["scanDirs"] {
                guard let arr = dirs as? [String] else { return fail("scanDirs 必须是字符串数组") }
                var expanded: [String] = []
                var warnings: [String] = []
                for d in arr where !d.isEmpty {
                    let p = (d as NSString).expandingTildeInPath
                    if !FileManager.default.fileExists(atPath: p) { warnings.append("目录不存在：\(p)") }
                    expanded.append(p)
                }
                root["scanDirs"] = expanded
                switch writeRegistry(root) {
                case .err(let m): return fail(m, code: "io")
                case .ok:
                    return emit(["ok": true, "scanDirs": expanded, "warnings": warnings])
                }
            }
            switch writeRegistry(root) {
            case .err(let m): return fail(m, code: "io")
            case .ok:
                return emit(["ok": true, "config": ["reserveGB": (root["reserveGB"] as? NSNumber)?.doubleValue ?? 6,
                                                     "scanDirs": (root["scanDirs"] as? [String]) ?? []]])
            }
        }
    }

    // MARK: - workgroups

    private static func workgroupList() -> Int32 {
        let groups = WorkgroupStore.load()
        let arr: [[String: Any]] = groups.map { ["id": $0.id, "name": $0.name, "members": $0.members] }
        return emit(["ok": true, "count": arr.count, "workgroups": arr])
    }

    private static func workgroupAdd(_ req: [String: Any]) -> Int32 {
        guard let name = (req["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let members = req["members"] as? [String], !members.isEmpty else {
            return fail("需要 name 与 members（模型 id 数组）", code: "usage", exit: 2)
        }
        switch readRegistry() {
        case .err(let m): return fail(m, code: "io")
        case .ok(let root):
            let ids = Set(recipes(root).compactMap { $0["id"] as? String })
            let unknown = members.filter { !ids.contains($0) }
            guard unknown.isEmpty else {
                return fail("这些 id 不在 registry 里：\(unknown.joined(separator: ", "))", code: "invalid")
            }
            var groups = WorkgroupStore.load()
            if let idx = groups.firstIndex(where: { $0.name == name }) {
                groups[idx] = Workgroup(id: groups[idx].id, name: name, members: members)
            } else {
                groups.append(Workgroup(id: "wg-" + UUID().uuidString.prefix(8).lowercased(),
                                        name: name, members: members))
            }
            WorkgroupStore.save(groups)
            return emit(["ok": true, "name": name, "members": members, "count": groups.count])
        }
    }

    private static func workgroupRemove(_ req: [String: Any]) -> Int32 {
        guard let name = req["name"] as? String, !name.isEmpty else {
            return fail("缺少 name", code: "usage", exit: 2)
        }
        var groups = WorkgroupStore.load()
        let before = groups.count
        groups.removeAll { $0.name == name }
        guard groups.count < before else { return fail("没有这个工作组：\(name)", code: "notfound", exit: 3) }
        WorkgroupStore.save(groups)
        return emit(["ok": true, "name": name, "count": groups.count])
    }
}
