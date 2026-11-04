// ============================================================
// 数据驱动的模型识别规则（registry.json → 分类 / 命名 / 引擎族）
// ------------------------------------------------------------
// 设计依据：docs/设计-模型识别层数据驱动_20261104.md
// 用户令（2026-11-04）：规则不能只针对本机现有模型，任何后加入的模型都要适用；
// 分类定性与显示名都应允许用户在数据里改，不要每次改规则都重编译。
//
// 优先级（见 ClassifyData.resolve）：modelOverrides > 用户 classifyRules > 配方声明
//                                > 内置默认规则 > 兜底（.chat / .part）
// 本文件只提供“数据 + 匹配”，不改任何现有行为；接线在 ModelManager / ModelCatalog 里完成。
// ============================================================

import Foundation

// MARK: - 通配符

/// 大小写不敏感的通配符：`*` 匹配任意串（含空）。不含 `*` 时退化为「包含」。
/// 只支持 `*`，不引入正则引擎 —— 规则要能被非程序员读懂。
enum Glob {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = pattern.lowercased(), t = text.lowercased()
        guard !p.isEmpty else { return false }
        if !p.contains("*") { return t.contains(p) }

        let parts = p.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var cursor = t.startIndex
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            let isFirst = (i == 0)
            let isLast = (i == parts.count - 1)
            if isFirst {
                guard t.hasPrefix(part) else { return false }
                cursor = t.index(cursor, offsetBy: part.count)
            } else if isLast {
                // 尾段：必须在光标之后、且刚好贴到末尾
                guard let r = t.range(of: part, options: .backwards, range: cursor..<t.endIndex),
                      r.upperBound == t.endIndex else { return false }
                return true
            } else {
                guard let r = t.range(of: part, range: cursor..<t.endIndex) else { return false }
                cursor = r.upperBound
            }
        }
        return true
    }
}

// MARK: - 匹配条件

/// 一条匹配条件。多个字段同时存在时是 **AND**（都满足才算命中）。
struct MatchSpec {
    var name: [String] = []        // 显示名 / 目录名 通配符
    var path: [String] = []        // 绝对路径 通配符
    var engine: [String] = []      // 引擎族名（不是引擎自称；先用 engineFamilies 归族）
    var role: ModelRole? = nil
    /// 排除角色：命中该角色时这条规则不成立。用途——部件规则必须写 `notRole: "main"`，
    /// 否则像 `Qwen3.8-27B-…-MTP` 这种「主权重目录名里带 MTP」的模型会被误判成部件。
    var notRole: ModelRole? = nil
    var port: Int? = nil
    var isMatchAll: Bool = false   // 空条件 = 匹配一切（仅在显式声明时成立）

    static func parse(_ obj: Any?) -> MatchSpec? {
        guard let d = obj as? [String: Any] else { return nil }
        var m = MatchSpec()
        m.name    = (d["name"] as? String).map { [$0] } ?? (d["name"] as? [String] ?? [])
        m.path    = (d["path"] as? String).map { [$0] } ?? (d["path"] as? [String] ?? [])
        m.engine  = (d["engine"] as? String).map { [$0] } ?? (d["engine"] as? [String] ?? [])
        if let r = d["role"] as? String, !r.isEmpty { m.role = ModelRole(rawValue: r) }
        if let r = d["notRole"] as? String, !r.isEmpty { m.notRole = ModelRole(rawValue: r) }
        if let p = (d["port"] as? NSNumber)?.intValue { m.port = p }
        if (d["any"] as? Bool) == true { m.isMatchAll = true }
        let empty = m.name.isEmpty && m.path.isEmpty && m.engine.isEmpty
            && m.role == nil && m.notRole == nil && m.port == nil && !m.isMatchAll
        return empty ? nil : m
    }

    /// 子串/通配符判定：任一模式命中即可（同一字段内是 OR，字段之间是 AND）。
    func matches(name: String, path: String, engineFamily: String?, role: ModelRole?, port: Int?) -> Bool {
        if isMatchAll { return true }
        let hayName = name.lowercased()
        let tail = ((path as NSString).lastPathComponent).lowercased()
        if !self.name.isEmpty {
            guard self.name.contains(where: { Glob.matches($0, hayName) || Glob.matches($0, tail) }) else { return false }
        }
        if !self.path.isEmpty {
            guard self.path.contains(where: { Glob.matches($0, path) }) else { return false }
        }
        if !self.engine.isEmpty {
            guard let fam = engineFamily, self.engine.contains(where: { $0.lowercased() == fam.lowercased() })
            else { return false }
        }
        if let r = self.role, role != r { return false }
        if let nr = self.notRole, role == nr { return false }
        if let p = self.port, port != p { return false }
        return true
    }

    var isEmpty: Bool {
        name.isEmpty && path.isEmpty && engine.isEmpty
            && role == nil && notRole == nil && port == nil && !isMatchAll
    }
}

// MARK: - 规则与覆盖

/// 分类规则：命中后决定「算什么类别 / 是主模型还是部件 / 显示什么小标签 / 是否隐藏」。
struct ClassifyRule {
    var match: MatchSpec
    var role: ModelRole? = nil
    var category: ModelCategory? = nil
    var label: String? = nil       // 例如 "LoRA" / "视觉投影"，显示在部件说明里
    var hidden: Bool = false       // 默认折叠、不出卡片

    static func parse(_ obj: [String: Any]) -> ClassifyRule? {
        guard let m = MatchSpec.parse(obj["match"]) else { return nil }
        var r = ClassifyRule(match: m)
        if let s = obj["role"] as? String, !s.isEmpty { r.role = ModelRole(rawValue: s) }
        if let s = obj["category"] as? String, !s.isEmpty { r.category = ModelCategory(rawValue: s.lowercased()) }
        if let s = obj["label"] as? String, !s.isEmpty { r.label = s }
        if let b = obj["hidden"] as? Bool { r.hidden = b }
        return r
    }
}

/// 名称/身份覆盖：按路径或名字把显示名、别名、类别、媒体口径、是否隐藏钉死。
struct ModelOverride {
    var match: MatchSpec
    var title: String? = nil
    var aliases: [String] = []
    var category: ModelCategory? = nil
    var media: String? = nil       // "mlxserve" / "llama.cpp" / "comfyui" …
    var hidden: Bool = false

    static func parse(_ obj: [String: Any]) -> ModelOverride? {
        guard let m = MatchSpec.parse(obj["match"]) else { return nil }
        var o = ModelOverride(match: m)
        if let s = obj["title"] as? String, !s.isEmpty { o.title = s }
        o.aliases = (obj["aliases"] as? [String]) ?? []
        if let s = obj["category"] as? String, !s.isEmpty { o.category = ModelCategory(rawValue: s.lowercased()) }
        if let s = obj["media"] as? String, !s.isEmpty { o.media = s }
        if let b = obj["hidden"] as? Bool { o.hidden = b }
        return o
    }
}

// MARK: - 一整套识别数据

struct ClassifyData {
    /// 引擎族 → 该族的引擎自称写法。**只做精确（大小写不敏感）匹配**，
    /// 不做子串互相包含 —— 那正是 `mlx-serve` 认领 `MLX` 运行行的元凶。
    var engineFamilies: [String: [String]] = [:]
    /// 用户规则，自上而下，先命中先赢
    var rules: [ClassifyRule] = []
    /// 用户覆盖
    var overrides: [ModelOverride] = []
    /// 是否在用户规则之后继续用内置默认规则
    var useBuiltin: Bool = true

    // MARK: 解析

    /// 从 registry.json 的根对象里取 `engineFamilies` / `classifyRules` / `modelOverrides` / `defaults`。
    static func load(from registry: [String: Any]?) -> ClassifyData {
        var d = ClassifyData()
        guard let root = registry else { d.engineFamilies = Self.builtinEngineFamilies; return d }

        if let fams = root["engineFamilies"] as? [String: [String]] {
            d.engineFamilies = fams
        } else if let fams = root["engineFamilies"] as? [String: Any] {
            for (k, v) in fams {
                if let arr = v as? [String] { d.engineFamilies[k] = arr }
                else if let s = v as? String { d.engineFamilies[k] = [s] }
            }
        }
        if d.engineFamilies.isEmpty { d.engineFamilies = Self.builtinEngineFamilies }

        if let arr = root["classifyRules"] as? [[String: Any]] {
            d.rules = arr.compactMap { ClassifyRule.parse($0) }
        }
        if let arr = root["modelOverrides"] as? [[String: Any]] {
            d.overrides = arr.compactMap { ModelOverride.parse($0) }
        }
        if let defs = root["defaults"] as? [String: Any],
           let b = defs["useBuiltinClassify"] as? Bool {
            d.useBuiltin = b
        }
        return d
    }

    // MARK: 引擎归族

    /// 把引擎自称映射成族名。没登记过的引擎原样返回（自己一族），绝不猜。
    func family(of engine: String?) -> String? {
        guard let e = engine?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return nil }
        let low = e.lowercased()
        for (fam, members) in engineFamilies {
            if members.contains(where: { $0.lowercased() == low }) { return fam }
        }
        // 自称里带版本/路径时，退一步做「包含」但只认**族长整词**，且要求族名足够长（≥4）
        for (fam, members) in engineFamilies where fam.count >= 4 {
            let key = fam.lowercased()
            if low.contains(key) { return fam }
            if members.contains(where: { m in m.count >= 4 && low.contains(m.lowercased()) }) { return fam }
        }
        return e
    }

    /// 两个引擎自称是否同族（替代原来「字符串互相包含」的判定）
    func sameFamily(_ a: String?, _ b: String?) -> Bool {
        guard let fa = family(of: a), let fb = family(of: b) else { return false }
        return fa.lowercased() == fb.lowercased()
    }

    // MARK: 解析一条模型的身份

    struct Resolved {
        var category: ModelCategory?
        var role: ModelRole?
        var title: String?
        var aliases: [String] = []
        var media: String?
        var hidden: Bool = false
        var label: String?
        /// 命中的规则来源，供 `--explain` 打印
        var evidence: String = ""
    }

    /// 依次按 覆盖 > 用户规则 > (内置规则) 解析。`builtinRules` 由 ModelClassifier 提供，
    /// 保证「数据里没写」时行为与旧版一致。
    /// 依次按 覆盖 > 用户规则 > 配方声明 > 内置规则 解析。
    /// `builtinRules` 由 ModelClassifier 提供，保证「数据里没写」时行为与旧版一致。
    func resolve(name: String, path: String, role: ModelRole, engineFamily: String?,
                 port: Int?, recipeCategory: ModelCategory? = nil,
                 builtinRules: [ClassifyRule]) -> Resolved {
        var out = Resolved()
        var hits: [String] = []

        // ① 覆盖：可改名字/别名/类别/媒体口径/隐藏
        for (i, o) in overrides.enumerated()
        where o.match.matches(name: name, path: path, engineFamily: engineFamily, role: role, port: port) {
            if out.title == nil, let t = o.title { out.title = t }
            out.aliases.append(contentsOf: o.aliases)
            if out.category == nil, let c = o.category { out.category = c }
            if out.media == nil, let m = o.media { out.media = m }
            if o.hidden { out.hidden = true }
            hits.append("modelOverrides[\(i)]")
        }

        // ② 用户规则（自上而下，先命中先赢）
        var hitUserRule = false
        for (i, r) in rules.enumerated()
        where r.match.matches(name: name, path: path, engineFamily: engineFamily, role: role, port: port) {
            if out.role == nil, let rr = r.role { out.role = rr }
            if out.category == nil, let c = r.category { out.category = c }
            if out.label == nil, let l = r.label { out.label = l }
            if r.hidden { out.hidden = true }
            hits.append("classifyRules[\(i)]" + (r.label.map { "(\($0))" } ?? ""))
            hitUserRule = true
            break
        }

        // ③ 配方声明（用户没在规则里定，才轮到配方）
        if !hitUserRule, out.category == nil, let c = recipeCategory {
            out.category = c
            hits.append("配方 category=\(c.rawValue)")
        }

        // ④ 内置默认规则（可被 defaults.useBuiltinClassify=false 整体关掉）
        if useBuiltin, out.category == nil || out.role == nil {
            for (i, r) in builtinRules.enumerated()
            where r.match.matches(name: name, path: path, engineFamily: engineFamily, role: role, port: port) {
                if out.role == nil, let rr = r.role { out.role = rr }
                if out.category == nil, let c = r.category { out.category = c }
                if out.label == nil, let l = r.label { out.label = l }
                if r.hidden { out.hidden = true }
                hits.append("builtin[\(i)]" + (r.label.map { "(\($0))" } ?? ""))
                break
            }
        }

        out.evidence = hits.isEmpty ? "无规则命中，走兜底" : hits.joined(separator: " > ")
        if out.role == nil { out.role = role }         // 角色默认取磁盘事实
        return out
    }

    // MARK: 内置默认

    /// 内置引擎族（只有这些词出了名；未登记的引擎自成一族）
    static let builtinEngineFamilies: [String: [String]] = [
        "mlx-serve":  ["mlx-serve", "mlxserve", "mlx_serve"],
        "mlx-vlm":    ["mlx_vlm.server", "mlx-vlm", "mlx_vlm", "mlxvlm"],
        "mlx-lm":     ["mlx_lm.server", "mlx-lm", "mlx_lm", "mlxlm"],
        "llama.cpp":  ["llama-server", "llama_server", "llama.cpp", "llama-cpp", "llamacpp", "llamafile"],
        "splash":     ["splash"],
        "strata":     ["strata"],
        "omlx":       ["omlx"],
        "ollama":     ["ollama"],
        "lm-studio":  ["lm-studio", "lmstudio", "lm studio"],
        "vllm":       ["vllm"],
        "comfyui":    ["comfyui", "comfy", "main.py"],
        "a1111":      ["a1111", "webui.py", "stable-diffusion-webui", "forge", "reforge", "sd.next"],
        "draw-things": ["draw things", "draw-things", "drawthings"],
        "whisper":    ["whisper", "mlx-whisper", "mlx_whisper", "mlx-whisperx", "whisperx"],
    ]

    /// 内置默认分类规则（等价于旧版四张硬编码词表 + part 规则），
    /// 放在这里是为了「没配置也能用」，同时用户可用 `defaults.useBuiltinClassify:false` 整个关掉。
    static let builtinRules: [ClassifyRule] = {
        func rule(_ hints: [String], _ cat: ModelCategory) -> [ClassifyRule] {
            hints.map { h in
                ClassifyRule(match: MatchSpec(name: ["*\(h)*"], path: [], engine: [], role: nil, port: nil),
                             category: cat)
            }
        }
        var out: [ClassifyRule] = []
        // 部件：先判部件，避免 LoRA/投影被当成独立模型。
        // 角色用 ModelIdentity 里已有的细分类（lora / projector / mtp / vae / textEncoder），
        // 类别统一 .part（跟随主模型），label 只用于界面说明。
        // 部件词分两组：
        //   · 无条件组：这些词出现在名字里就是件（loRA / ControlNet / 投影 / VAE / 文本编码器），
        //     即使磁盘判定它是「主权重」也照样归部件 —— 否则 ControlNetModel 这种会被当成独立模型。
        //   · 排除主权重组：`mtp` / `draft` 这类容易与主模型名冲突（`…-4bit-MTP` 是主权重包），
        //     只在角色不是主权重时才成立。
        let partHints: [(String, ModelRole, Bool)] = [
            ("lora", .lora, false), ("lycoris", .lora, false),
            ("controlnet", .lora, false), ("ipadapter", .lora, false), ("ip-adapter", .lora, false),
            ("mmproj", .projector, false), ("vision-tower", .projector, false),
            ("vision_tower", .projector, false), ("clip_vision", .projector, false),
            ("text_encoder", .textEncoder, false), ("vae", .vae, false),
            ("draft", .mtp, true), ("mtp", .mtp, true),
        ]
        for (h, r, needsNonMain) in partHints {
            let spec = needsNonMain ? MatchSpec(name: ["*\(h)*"], notRole: .main)
                                    : MatchSpec(name: ["*\(h)*"])
            out.append(ClassifyRule(match: spec, role: r, category: .part, label: h))
        }
        out += rule(["flux", "sdxl", "sd3", "stable-diffusion", "stable_diffusion", "qwen-image", "qwen_image",
                     "kolors", "playground", "juggernaut", "realvis", "pony", "checkpoint", "deepfloyd",
                     "pixart", "hidream", "chroma", "instantid", "controlnet", "ipadapter"], .image)
        out += rule(["wan2", "wan-2", "hunyuanvideo", "hunyuan-video", "ltx", "cogvideo", "minimax-h3",
                     "minimax_h3", "i2v", "t2v", "svd", "svd-xt", "seedance", "kling"], .video)
        out += rule(["whisper", "kokoro", "piper", "coqui", "chattts", "xtts", "tts", "bark", "musicgen",
                     "stable-audio"], .audio)
        out += rule(["embed", "rerank", "bge", "gte", "minilm", "e5-", "e5_", "sentence-transformers",
                     "clip-vit", "colbert", "ecapa", "spkrec", "wav2vec"], .embedding)
        out += rule(["grounding-dino", "videomae", "detr", "sam2", "depth-anything"], .part)
        out.append(ClassifyRule(match: MatchSpec(path: ["*/ComfyUI/*"]), category: .image))
        return out
    }()

    // MARK: - 便捷入口（供 ModelCatalog / ModelClassifier / Recipe 使用）

    /// 只有内置规则、不含用户数据的实例：给自检与「无配置」场景用，不读盘。
    static let builtin = ClassifyData(engineFamilies: builtinEngineFamilies,
                                      rules: [], overrides: [], useBuiltin: true)

    /// 每次调用都从 registry.json 读盘（与 LauncherConfig 同口径：改数据即生效，无需重编译）。
    /// 读不到或字段缺失时回落内置族表，绝不因为配置写坏而让识别层瘫掉。
    static func loadFromRegistry() -> ClassifyData {
        var root: [String: Any]? = nil
        if let d = try? Data(contentsOf: URL(fileURLWithPath: SupportDir.registry)),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            root = obj
        }
        return load(from: root)
    }

    /// 用**内置族表**判断两个引擎自称是否同族（供 `Recipe.matches` 使用；
    /// 用户自定义的族表由实例方法 `sameFamily` 负责）。
    static func sameBuiltinFamily(_ a: String?, _ b: String?) -> Bool {
        func fam(_ s: String?) -> String? {
            guard let e = s?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return nil }
            let low = e.lowercased()
            for (f, members) in builtinEngineFamilies where members.contains(where: { $0.lowercased() == low }) {
                return f.lowercased()
            }
            for (f, members) in builtinEngineFamilies {
                if low.contains(f.lowercased()) { return f.lowercased() }
                if members.contains(where: { $0.count >= 4 && low.contains($0.lowercased()) }) { return f.lowercased() }
            }
            return low
        }
        guard let fa = fam(a), let fb = fam(b) else { return false }
        return fa == fb
    }
}
