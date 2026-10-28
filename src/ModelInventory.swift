// ============================================================
// 磁盘清单层（方案 M3）
// ============================================================
//
// 「盘上有哪些模型」本身是一等公民：引擎没登记、也没在跑的权重，用户同样要能看到。
//
// 只扫**已知仓库 + 用户声明目录**，不做全盘扫描：
//   · Hugging Face 缓存（`models--<org>--<name>` 目录名就是 repo id，和引擎自报 id 天然对得上）
//   · Ollama manifests / blobs
//   · LM Studio `models/<publisher>/<repo>/`
//   · ComfyUI 的模型子目录
//   · `engines.json` 里的 `modelDirs`（用户自己加的）
//
// 去重按 realpath（符号链接 / HF 快照里指向 blobs 的链接不算两份）。

import Foundation

struct DiskUnit {
    var path: String              // 展示路径（$HOME 缩成 ~）
    var realPath: String
    var source: String            // 来源仓库名（给人看的）
    var identity: ModelIdentity
    /// 去重键：优先用最大权重文件的 dev:ino（硬链接副本折叠），否则用 realpath
    var dedupeKey: String { identity.inodeKey ?? realPath }
}

/// 清单里的一行：可能是「正在跑 / 已装载」，也可能只是「在盘、无引擎登记」
struct InventoryRow {
    var title: String
    var detail: String            // 路径 / 来源 / 引擎
    var state: ModelState
    var diskGB: Double
    var memGB: Double
    var note: String = ""
}

struct InventorySnapshot {
    var rows: [InventoryRow] = []
    var scannedRoots: [String] = []
    var runningCount = 0
    var idleCount = 0
    var unregisteredCount = 0
    var uncertainCount = 0
    var totalDiskGB: Double = 0
    var truncated = false
}

final class ModelInventory {
    /// 单个仓库最多收多少个模型单元，防止一个巨型缓存把界面塞满
    private let perRootLimit = 200
    /// 单元内部最多向下走几层找权重文件
    private let depthLimit = 3

    private var identityCache: [String: (size: Int64, mtime: Date, id: ModelIdentity)] = [:]
    /// 引擎 argv 里声明的权重目录（由运行时快照传进来）
    var engineDirs: [String] = []

    // ---------- 配置 ----------
    struct Config {
        var extraDirs: [String] = []
        var includeDefaults = true
        /// 是否把「引擎 argv 里声明的目录」也当扫描根。回归测试要关掉它，
        /// 否则本机真在跑的引擎会把真实权重带进断言。
        var includeEngineDirs = true
    }

    /// 读 `~/Library/Application Support/Dockolate/engines.json` 的 `modelDirs`（与端口配置同一个文件）
    static func loadConfig() -> Config {
        var c = Config()
        let path = NSHomeDirectory() + "/Library/Application Support/Dockolate/engines.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return c }
        if let dirs = obj["modelDirs"] as? [String] {
            c.extraDirs = dirs.map { ($0 as NSString).expandingTildeInPath }
        }
        if let b = obj["scanDefaultDirs"] as? Bool { c.includeDefaults = b }
        return c
    }

    /// 默认扫描根：只放「模型仓库」这种有稳定约定的位置，不猜用户的自定义目录
    static func defaultRoots() -> [(path: String, source: String, layout: Layout)] {
        let home = NSHomeDirectory()
        var out: [(String, String, Layout)] = [
            (home + "/.cache/huggingface/hub", "HF 缓存", .hfCache),
            (home + "/.ollama/models", "Ollama", .ollama),
            (home + "/.lmstudio/models", "LM Studio", .lmStudio),
            (home + "/Library/Application Support/lm-studio/models", "LM Studio", .lmStudio),
            (home + "/mlx-models", "用户模型目录", .generic),
            (home + "/models", "用户模型目录", .generic),
        ]
        // ComfyUI：常见的两处落地位置，存在才扫
        for base in [home + "/ComfyUI/models", home + "/Documents/ComfyUI/models"] {
            for sub in ["checkpoints", "unet", "diffusion_models", "loras", "vae", "text_encoders"] {
                out.append((base + "/" + sub, "ComfyUI", .comfy))
            }
        }
        return out.filter { FileManager.default.fileExists(atPath: $0.0) }
    }

    enum Layout { case hfCache, ollama, lmStudio, comfy, generic }

    // ---------- 扫描 ----------
    func scan(config: Config = ModelInventory.loadConfig()) -> [DiskUnit] {
        var roots = config.includeDefaults ? ModelInventory.defaultRoots() : []
        for d in config.extraDirs {
            roots.append((d, "自定义目录", .generic))
        }
        if config.includeEngineDirs {
            for d in engineDirs where !roots.contains(where: { $0.path == d }) {
                roots.append((d, "引擎声明的目录", .generic))
            }
        }
        var units: [DiskUnit] = []
        var seenReal = Set<String>()
        for root in roots {
            var found: [DiskUnit] = []
            if root.layout == .ollama {
                found = scanOllama(path: root.path)
            } else {
                walk(root.path, source: root.source, depth: 0, into: &found)
            }
            for u in found {
                guard !seenReal.contains(u.dedupeKey) else { continue }
                seenReal.insert(u.dedupeKey)
                units.append(u)
            }
        }
        return units
    }

    /// 递归下行：能在这一层认出「主权重」就收下且不再往下走；
    /// 认出的是集合（身份层返回 nil）就继续往子目录走，最多 depthLimit 层。
    /// 跳过 `blobs` / `refs` / `.no_exist` 这类 HF 缓存内部结构 —— blobs 是同一份字节的副本，
    /// 真身已经在 snapshots 下按 realpath 去重过了。
    private func walk(_ path: String, source: String, depth: Int, into units: inout [DiskUnit]) {
        guard units.count < perRootLimit else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            if let u = makeUnit(path: path, source: source) { units.append(u) }
            return
        }
        if let u = makeUnit(path: path, source: source) {
            units.append(u)
            return
        }
        guard depth < depthLimit else { return }
        let skip: Set<String> = ["blobs", "refs", ".no_exist", "__pycache__", ".git", "node_modules"]
        let children = ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") && !skip.contains($0) }
            .sorted()
        for child in children {
            var d: ObjCBool = false
            guard fm.fileExists(atPath: path + "/" + child, isDirectory: &d) else { continue }
            if d.boolValue {
                walk(path + "/" + child, source: source, depth: depth + 1, into: &units)
            } else {
                guard ModelIdentifier.weightExtsPublic.contains(where: { child.lowercased().hasSuffix($0) }) else { continue }
                if let u = makeUnit(path: path + "/" + child, source: source) { units.append(u) }
            }
        }
    }

    /// Ollama：manifests 下每层目录一个模型，manifest JSON 里带各层的字节数
    private func scanOllama(path: String) -> [DiskUnit] {
        let fm = FileManager.default
        let manifests = path + "/manifests"
        guard fm.fileExists(atPath: manifests) else { return [] }
        var out: [DiskUnit] = []
        var stack = [manifests]
        while let dir = stack.popLast(), out.count < perRootLimit {
            let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for it in items where !it.hasPrefix(".") {
                let p = dir + "/" + it
                var d: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &d) else { continue }
                if d.boolValue { stack.append(p); continue }
                guard it.hasSuffix(".json"),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let rel = p.replacingOccurrences(of: manifests + "/", with: "")
                let parts = rel.split(separator: "/").map(String.init)
                // registry/namespace/model/tag.json
                let tag = (it as NSString).deletingPathExtension
                let name = parts.count >= 2 ? "\(parts[parts.count - 2]):\(tag)" : tag
                var bytes: Int64 = 0
                if let layers = obj["layers"] as? [[String: Any]] {
                    for l in layers { bytes += (l["size"] as? NSNumber)?.int64Value ?? 0 }
                }
                var id = ModelIdentity()
                id.family = name
                id.role = .main
                id.format = "ollama"
                id.bytes = bytes
                id.files = (obj["layers"] as? [[String: Any]])?.count ?? 0
                if let cfg = obj["config"] as? [String: Any], let digest = cfg["digest"] as? String {
                    _ = digest    // 归档信息，界面不显示
                }
                out.append(DiskUnit(path: abbreviate(p), realPath: realPath(p), source: "Ollama", identity: id))
            }
        }
        return out
    }

    /// 目录/文件 → 一个模型单元（识别不出就返回 nil，避免把空目录当模型）
    private func makeUnit(path: String, source: String) -> DiskUnit? {
        let key = realPath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let size = unitSize(path)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? Date.distantPast
        if let c = identityCache[key], c.size == size, c.mtime == mtime {
            return DiskUnit(path: abbreviate(path), realPath: key, source: source, identity: c.id)
        }
        guard var id = ModelIdentifier.identify(path: path), id.files > 0 else { return nil }
        guard size > 0, id.hasModelEvidence else { return nil }   // 空壳或非模型大文件：不算
        id.bytes = size
        identityCache[key] = (size, mtime, id)
        return DiskUnit(path: abbreviate(path), realPath: key, source: source, identity: id)
    }

    /// 单元在盘字节：目录内权重文件合计（最多向下 depthLimit 层）
    private func unitSize(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value ?? 0
        }
        var total: Int64 = 0
        var depth = 0
        var dirs = [path]
        while let d = dirs.popLast(), depth <= depthLimit {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
            for it in items where !it.hasPrefix(".") {
                let p = d + "/" + it
                var sub: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &sub) else { continue }
                if sub.boolValue { dirs.append(p) }
                else if ModelIdentifier.weightExtsPublic.contains(where: { it.lowercased().hasSuffix($0) }) {
                    total += (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)??.int64Value ?? 0
                }
            }
            depth += 1
        }
        return total
    }

    // ---------- 对账 ----------
    /// 把运行时快照（引擎说它在跑什么）与磁盘清单合起来：
    /// 运行时行照原样进（状态可信），盘上多出来的进「在盘、无引擎登记」。
    func build(runtime: ModelSnapshot, config: Config = ModelInventory.loadConfig()) -> InventorySnapshot {
        var snap = InventorySnapshot()
        engineDirs = runtime.modelDirs
        let units = scan(config: config)
        snap.scannedRoots = (config.includeDefaults ? ModelInventory.defaultRoots().map { $0.path } : []) + config.extraDirs
        var used = Set<Int>()

        // 1) 运行时行
        for r in runtime.rows {
            // 取「最像的那一个」而不是「第一个像的」：同一家族常有 4bit/8bit 两个目录，
            // 按名字完全相等的得分最高，才不会把正在跑的 8bit 指到 4bit 的路径上。
            var matchIdx: Int?
            var bestScore = 0
            for (i, u) in units.enumerated() where !used.contains(i) {
                let s = Self.matchScore(runtimeName: r.name, unit: u)
                if s > bestScore || (s == bestScore && s > 0 && matchIdx != nil
                                     && u.identity.bytes > units[matchIdx!].identity.bytes) {
                    bestScore = s
                    matchIdx = i
                }
            }
            var detail = r.note
            var diskGB = 0.0
            if let i = matchIdx {
                used.insert(i)
                detail = units[i].source + " · " + units[i].path
                diskGB = Double(units[i].identity.bytes) / 1_073_741_824
            }
            snap.rows.append(InventoryRow(title: r.name, detail: detail, state: r.state,
                                          diskGB: diskGB, memGB: r.memGB, note: r.note))
            switch r.state {
            case .running: snap.runningCount += 1
            case .idle, .loading, .failed: snap.idleCount += 1
            case .uncertain: snap.uncertainCount += 1
            case .unloaded, .unregistered: break
            }
        }

        // 2) 盘上未被任何引擎登记的
        for (i, u) in units.enumerated() where !used.contains(i) {
            snap.rows.append(InventoryRow(title: u.identity.displayName,
                                          detail: u.source + " · " + u.path,
                                          state: .unregistered,
                                          diskGB: Double(u.identity.bytes) / 1_073_741_824,
                                          memGB: 0,
                                          note: "在盘、无引擎登记"))
            snap.unregisteredCount += 1
        }
        snap.totalDiskGB = snap.rows.reduce(0) { $0 + $1.diskGB }
        snap.rows.sort { a, b in
            if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
            return a.diskGB > b.diskGB
        }
        if snap.rows.count > 400 { snap.rows = Array(snap.rows.prefix(400)); snap.truncated = true }
        return snap
    }

    // ---------- 名字对账 ----------
    static func matches(runtimeName: String, unit: DiskUnit) -> Bool { matchScore(runtimeName: runtimeName, unit: unit) > 0 }

    /// 0 = 不像；3 = 名字完全相等；2 = 家族名相等；1 = 互相包含（弱证据）
    static func matchScore(runtimeName: String, unit: DiskUnit) -> Int {
        let a = norm(runtimeName)
        let base = norm((unit.path as NSString).lastPathComponent)
        let fam = norm(unit.identity.family ?? "")
        if base == a || norm(unit.identity.displayName) == a { return 3 }
        if fam == a { return 2 }
        // HF 缓存：仓库 id 的 `/` 在目录名里写成 `--`
        if unit.path.contains("models--") {
            if let r = unit.path.range(of: "models--") {
                let tail = String(unit.path[r.upperBound...])
                let repo = tail.replacingOccurrences(of: "/snapshots", with: "")
                    .replacingOccurrences(of: "--", with: "/")
                let repoLast = repo.split(separator: "/").last.map(String.init) ?? repo
                if norm(repo) == a || norm(repoLast) == a { return 3 }
            }
        }
        // 引擎 id 可能带量化后缀，磁盘名可能不带：互相包含只算弱证据（1 分）
        for c in [base, fam] where !c.isEmpty && (c.contains(a) || a.contains(c)) { return 1 }
        return 0
    }

    private static func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: ":latest", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // ---------- 杂项 ----------
    private func realPath(_ p: String) -> String {
        (p as NSString).resolvingSymlinksInPath
    }

    private func abbreviate(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }
}

extension ModelState {
    /// 清单里的排序权重：在跑的在最上，未登记的沉底
    var sortRank: Int {
        switch self {
        case .running: return 0
        case .loading: return 1
        case .idle: return 2
        case .uncertain: return 3
        case .failed: return 4
        case .unregistered: return 5
        case .unloaded: return 5
        }
    }
}
