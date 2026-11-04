// ============================================================
// 本地模型管理器：扫盘 → 分类 → 估算 → 拉起 / 卸载 / 工作组
// ============================================================
//
// 只做三件事，但每件都要能落地：
//   ① 把「盘上有什么」变成「这台机器能拉起什么」：权重字节 + 开销估算 + 当前可用内存 ⇒ 三色判据；
//   ② 拉起 / 卸载：靠 registry.json 的 recipes（命令可以是 shell 串，也可以是 argv；launchers.json 仅兼容回退），
//      Ollama / LM Studio 有内置适配器；没有配方的条目**明说**没配方，不假装能点；
//   ③ 工作组：把若干个模型绑成一个名字，一起拉起 / 一起停，并按合计内存判断能不能并存。
//
// 估算的诚实边界：权重字节来自磁盘（实测），额外开销是启发式（KV / 激活 / 框架开销）；
// 一旦这个模型在本机跑过，就把实测峰值记下来（observed.json），下次估算优先用实测值。

import Cocoa

extension String {
    /// `~` 展开（Swift 的 String 没有 NSString 那个便利属性）
    var expandingTildePath: String { (self as NSString).expandingTildeInPath }
}

/// 名字归一：小写、去掉分隔符与权重扩展名，便于「同一个模型的两种叫法」对上
func normName(_ s: String) -> String {
    var t = s.lowercased()
    for ext in [".safetensors", ".gguf", ".ckpt", ".pt", ".pth", ".bin"] where t.hasSuffix(ext) {
        t = String(t.dropLast(ext.count))
    }
    for ch in ["-", "_", " ", "/", ":", ".", "·", "（", "）", "(", ")"] {
        t = t.replacingOccurrences(of: ch, with: "")
    }
    return t
}

func realPathEqual(_ a: String, _ b: String) -> Bool {
    (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath
}

/// 把「管理入口目标」解析成条目。支持（按强度）：
///   条目 id 全等 → `recipe:<配方id>`（配方与磁盘条目合并成一张卡时解析到宿主条目）
///   → `engine:<引擎名/族名>` → 裸名字（显示名 / 目录名归一化全等）
/// 歧义一律返回错误 + 候选，**不猜**（用户对「按名字猜」零容忍）。
func resolveMgmtTarget(_ target: String, entries: [CatalogEntry],
                       config: LauncherConfig) -> (CatalogEntry?, String) {
    let t = target.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return (nil, "目标为空") }
    if let e = entries.first(where: { $0.id == t }) { return (e, "") }
    let low = t.lowercased()

    if low.hasPrefix("recipe:") {
        let rid = String(t.dropFirst("recipe:".count))
        if let e = entries.first(where: { $0.recipe?.id == rid }) { return (e, "") }
        if let r = config.recipes.first(where: { $0.id == rid }), let rp = r.path,
           let e = entries.first(where: { e in
               guard let dp = e.diskPath else { return false }
               return realPathEqual(rp, dp)
           }) {
            return (e, "")
        }
        return (nil, "没有这个配方：\(rid)")
    }

    if low.hasPrefix("engine:") {
        let en = String(t.dropFirst("engine:".count))
        let hits = entries.filter { e in
            let eng = e.engineName.isEmpty ? (e.recipe?.engine ?? "") : e.engineName
            return !eng.isEmpty && ClassifyData.sameBuiltinFamily(eng, en)
        }
        if hits.count == 1 { return (hits[0], "") }
        if hits.isEmpty { return (nil, "没有引擎「\(en)」的条目") }
        return (nil, "引擎「\(en)」对应多个条目，请指定 id：" + hits.map { $0.id }.joined(separator: "、"))
    }

    let key = normName(t)
    // 别名也算身份：用户在 modelOverrides 里写的 aliases 应能直接用来指定条目
    let data = ClassifyData.loadFromRegistry()
    func aliases(of e: CatalogEntry) -> [String] {
        data.overrides
            .filter { $0.match.matches(name: e.title, path: e.diskPath ?? "",
                                       engineFamily: nil, role: .main, port: e.port) }
            .flatMap { $0.aliases }
    }
    let hits = entries.filter { e in
        normName(e.title) == key
            || normName((((e.diskPath ?? "") as NSString).lastPathComponent)) == key
            || aliases(of: e).contains { normName($0) == key }
    }
    if hits.count == 1 { return (hits[0], "") }
    if hits.isEmpty { return (nil, "没有匹配「\(t)」的条目") }
    return (nil, "「\(t)」匹配多个条目，请指定 id：" + hits.map { $0.title }.joined(separator: "、"))
}

// ============================================================
// MARK: - 启动配方
// ============================================================

struct CommandSpec {
    var argv: [String]
    var isShell: Bool

    static func decode(_ any: Any?) -> CommandSpec? {
        if let s = any as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
            return CommandSpec(argv: ["/bin/bash", "-lc", s], isShell: true)
        }
        if let a = any as? [String], !a.isEmpty {
            return CommandSpec(argv: a, isShell: false)
        }
        return nil
    }

    var display: String { argv.joined(separator: " ") }
}

struct LaunchRecipe {
    var id: String
    var title: String?
    var engine: String?
    var modelPatterns: [String] = []
    /// 跟着主模型一起加载的部件（草稿头 / 投影）：清点时并进主模型那一行，不单独占一行
    var attachments: [String] = []
    var path: String?
    var port: Int?
    var category: String?
    var estMemGB: Double?
    var start: CommandSpec?
    var stop: CommandSpec?
    var log: String?
    var metrics: String?
    /// 媒体指标来源（生图 / 视频专用）：`comfyui`（走 /queue + /history）或
    /// `mlxserve`（走引擎日志）。声明了它就不再显示 prefill / decode —— 那是文本生成的口径。
    var media: String?
    var readyTimeoutSec: Double = 180
    var kind: String = "model"       // model｜service

    /// 媒体类别：由 category（image / video）判定，缺省按来源给默认值
    var mediaKind: MediaKind? {
        guard let m = media?.lowercased(), !m.isEmpty else { return nil }
        switch (category ?? "").lowercased() {
        case "video": return .video
        case "image": return .image
        default: return m.contains("comfy") ? .image : .video
        }
    }

    static func parse(_ obj: [String: Any]) -> LaunchRecipe? {
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        var r = LaunchRecipe(id: id)
        r.title = obj["title"] as? String
        r.engine = obj["engine"] as? String
        if let p = obj["modelPatterns"] as? [String] { r.modelPatterns = p.filter { !$0.isEmpty } }
        if let m = obj["model"] as? String, !m.isEmpty { r.modelPatterns.append(m) }
        if let a = obj["attachments"] as? [String] { r.attachments = a.filter { !$0.isEmpty } }
        r.path = (obj["path"] as? String)?.expandingTildePath
        r.port = (obj["port"] as? NSNumber)?.intValue
        r.category = obj["category"] as? String
        r.estMemGB = (obj["estMemGB"] as? NSNumber)?.doubleValue
        r.start = CommandSpec.decode(obj["start"])
        r.stop = CommandSpec.decode(obj["stop"])
        r.log = (obj["log"] as? String)?.expandingTildePath
        r.metrics = obj["metrics"] as? String
        if let m = obj["media"] as? String, !m.isEmpty { r.media = m }
        if let t = (obj["readyTimeoutSec"] as? NSNumber)?.doubleValue, t > 5 { r.readyTimeoutSec = t }
        if let k = obj["kind"] as? String, !k.isEmpty { r.kind = k }
        return r
    }

    /// 配方 ↔ 一个磁盘/运行时模型 是否指同一个东西。
    /// ⚠️ 名字只比「标题 + 路径最后一段」：拿整条路径比会把 HF 缓存里
    /// `models--org--某个名字` 的另一份副本也算成同一个模型（实测会把 26 GB 估算挂到 localfourbit 上）。
    func matches(name: String, path: String?, engine: String?, port: Int?) -> Bool {
        if let rp = self.path, let p = path, realPathEqual(rp, p) { return true }
        let tail = ((path ?? "") as NSString).lastPathComponent
        let hay = normName(name + " " + tail)
        for p in modelPatterns where !p.isEmpty {
            if hay.contains(normName(p)) { return true }
        }
        if let e = self.engine, let en = engine, !en.isEmpty,
           ClassifyData.sameBuiltinFamily(e, en) {
            // 引擎同族时，端口是唯一硬证据。
            if let rp = self.port, let pp = port { return rp == pp }
            // ⛔ 2026-11-04：引擎同族但配方未声明端口，不再直接认定是它 ——
            //    原来这条（`self.port == nil { return true }`）让 `engine:"mlx-serve"` 的 H3 配方
            //    认领了 `engine:"MLX"`（mlx_vlm）的运行行，把别的引擎的状态/内存贴到这张卡上。
            //    设计见 docs/设计-模型识别层数据驱动_*.md §四。
            return false
        }
        // 既没声明引擎、也没给权重模式的配方（ComfyUI 这类「服务」配方）：
        // 端口就是它唯一的身份——监听在这个端口上的进程就是它。
        // 不认这一条，服务卡片永远匹配不上自己的运行行：界面里会同时出现
        // 「ComfyUI（未运行）」与「ComfyUI（运行中）」两张卡。
        if self.engine == nil, modelPatterns.isEmpty, let rp = self.port, let pp = port, rp == pp {
            return true
        }
        return false
    }
}

struct LauncherConfig {
    var recipes: [LaunchRecipe] = []
    var reserveGB: Double = 6
    var scanDirs: [String] = []
    var warnings: [String] = []

    static var path: String {
        SupportDir.launchers
    }

    /// 单一真源（2026-10-29 合并）：recipes + 调度策略 + 能力都在这里。
    /// launchers.json 降级为兼容回退——只在 registry 缺失/无配方时读，避免升级中途配方丢失。
    static var registryPath: String {
        SupportDir.registry
    }

    static func load() -> LauncherConfig {
        if let c = parse(url: registryPath, label: "registry.json"), !c.recipes.isEmpty {
            return c
        }
        if let c = parse(url: path, label: "launchers.json") { return c }
        return LauncherConfig()
    }

    private static func parse(url: String, label: String) -> LauncherConfig? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: url)) else { return nil }
        var c = LauncherConfig()
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            c.warnings.append(label + " 不是合法 JSON，已忽略")
            return c
        }
        if let r = (obj["reserveGB"] as? NSNumber)?.doubleValue, r >= 0 { c.reserveGB = r }
        if let dirs = obj["scanDirs"] as? [String] {
            c.scanDirs = dirs.map { $0.expandingTildePath }
        }
        if let arr = obj["recipes"] as? [[String: Any]] {
            for o in arr {
                if let r = LaunchRecipe.parse(o) { c.recipes.append(r) }
                else { c.warnings.append(label + " 配方缺 id，已跳过：" + (o["title"] as? String ?? "?")) }
            }
        }
        c.validateSemantics(label: label)
        return c
    }

    /// 语义校验（2026-11-03 用户要求「AI 改坏配置也不能让中枢起错东西」）：
    /// 格式合法但内容错的配置最容易出事，这里把它们**显式列成 warnings**，
    /// 由 `--doctor` / `--api {"op":"doctor"}` 与 GUI 的状态行读出来。
    /// 原则：只报警、不擅自删除用户配置（唯一例外是重复 id 的后一条，见下）。
    mutating func validateSemantics(label: String) {
        var seenIds = Set<String>()
        var seenPorts: [Int: String] = [:]
        var dropped = Set<String>()
        for r in recipes {
            if seenIds.contains(r.id) {
                warnings.append("\(label)：配方 id 重复「\(r.id)」，后一条不会生效")
                dropped.insert(r.id)
            }
            seenIds.insert(r.id)
            if let p = r.port {
                guard (1...65535).contains(p) else {
                    warnings.append("\(label)：配方「\(r.id)」端口 \(p) 越界")
                    continue
                }
                if let owner = seenPorts[p] {
                    warnings.append("\(label)：端口 \(p) 同时被「\(owner)」与「\(r.id)」声明，后者起不来")
                } else {
                    seenPorts[p] = r.id
                }
            }
            if r.start == nil && r.kind != "service" {
                warnings.append("\(label)：配方「\(r.id)」没有 start，界面只能识别、不能拉起")
            }
            if let e = r.estMemGB, !(e > 0 && e < 4096) {
                warnings.append("\(label)：配方「\(r.id)」estMemGB=\(e) 不合理")
            }
        }
        if !dropped.isEmpty { recipes.removeAll { dropped.contains($0.id) } }
    }

    /// 配方声明的权重目录也要当扫描根 —— 「从哪儿启动就去哪儿清点」。
    /// 但**已经落在扫描根里的路径不再重复加**：同一份权重被两个根各扫一遍会变成两行。
    var extraScanRoots: [String] {
        var out = scanDirs
        func covered(_ p: String) -> Bool {
            out.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
        for r in recipes where r.kind != "service" {
            guard let p = r.path else { continue }
            var isDir: ObjCBool = false
            let dir: String
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                dir = p
            } else {
                dir = (p as NSString).deletingLastPathComponent
            }
            if !covered(dir) { out.append(dir) }
        }
        return Array(Set(out)).sorted()
    }

    func recipe(forName name: String, path: String?, engine: String?, port: Int?) -> LaunchRecipe? {
        recipes.first { $0.matches(name: name, path: path, engine: engine, port: port) }
    }
}

// ============================================================
// MARK: - 工作组
// ============================================================

struct Workgroup: Codable, Equatable {
    var id: String
    var name: String
    var members: [String]
}

final class WorkgroupStore {
    static let path = SupportDir.workgroups

    static func load() -> [Workgroup] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let name = o["name"] as? String, let members = o["members"] as? [String] else { return nil }
            return Workgroup(id: (o["id"] as? String) ?? UUID().uuidString, name: name, members: members)
        }
    }

    static func save(_ groups: [Workgroup]) {
        let arr: [[String: Any]] = groups.map { ["id": $0.id, "name": $0.name, "members": $0.members] }
        guard let d = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// ============================================================
// MARK: - 实测内存（估算的校准项）
// ============================================================

final class ObservedMemory {
    static let path = SupportDir.observed
    private var values: [String: Double] = [:]

    init() { load() }

    private func load() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: ObservedMemory.path)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        for (k, v) in obj { if let n = v as? NSNumber { values[k] = n.doubleValue } }
    }

    func value(for key: String) -> Double? { values[key] }

    /// 只升不降：一次跑出 28 GB，下次估算就别退回 20 GB
    func note(key: String, memGB: Double) {
        guard memGB > 0.2 else { return }
        if let old = values[key], old >= memGB { return }
        values[key] = memGB
        if let d = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(
                atPath: (ObservedMemory.path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: ObservedMemory.path), options: .atomic)
        }
    }
}

// ============================================================
// MARK: - 分类
// ============================================================

enum ModelCategory: String, CaseIterable {
    case chat, image, video, audio, embedding, part, service, other

    var title: String {
        switch self {
        case .chat:      return "对话 / 推理"
        case .image:     return "生图"
        case .video:     return "视频"
        case .audio:     return "语音"
        case .embedding: return "嵌入 / 检索"
        case .part:      return "部件（跟随主模型）"
        case .service:   return "服务"
        case .other:     return "其它"
        }
    }
    var order: Int {
        switch self {
        case .chat: return 0
        case .image: return 1
        case .video: return 2
        case .audio: return 3
        case .embedding: return 4
        case .service: return 5
        case .part: return 6
        case .other: return 7
        }
    }
    var icon: String {
        switch self {
        case .chat: return "◍"
        case .image: return "▤"
        case .video: return "▷"
        case .audio: return "♪"
        case .embedding: return "⊞"
        case .part: return "◌"
        case .service: return "⚙"
        case .other: return "•"
        }
    }
}

enum ModelClassifier {
    /// 旧签名（自检、未接线调用方）：只用内置规则，不读盘 —— 行为与改造前等价。
    static func classify(name: String, path: String, role: ModelRole, categoryHint: String?) -> ModelCategory {
        classify(name: name, path: path, role: role, categoryHint: categoryHint,
                 data: .builtin, engineFamily: nil, port: nil)
    }

    /// 新签名：`data` 来自 registry.json（engineFamilies / classifyRules / modelOverrides），
    /// 用户改数据即生效，不必重编译。见 docs/设计-模型识别层数据驱动_*.md。
    static func classify(name: String, path: String, role: ModelRole, categoryHint: String?,
                         data: ClassifyData, engineFamily: String? = nil, port: Int? = nil) -> ModelCategory {
        resolve(name: name, path: path, role: role, categoryHint: categoryHint,
                data: data, engineFamily: engineFamily, port: port).category ?? .chat
    }

    /// 解析完整身份：类别 / 角色 / 显示名 / 别名 / 媒体口径 / 是否隐藏 / 命中证据。
    static func resolve(name: String, path: String, role: ModelRole, categoryHint: String?,
                        data: ClassifyData, engineFamily: String? = nil, port: Int? = nil) -> ClassifyData.Resolved {
        let hint = categoryHint.flatMap { ModelCategory(rawValue: $0.lowercased()) }
        var r = data.resolve(name: name, path: path, role: role, engineFamily: engineFamily,
                             port: port, recipeCategory: hint, builtinRules: ClassifyData.builtinRules)
        // 非主权重一定不是独立模型：没被显式归类就落到「部件」
        if role != .main, r.category == nil { r.category = .part }
        if r.category == nil { r.category = .chat }
        return r
    }
}

// ============================================================
// MARK: - 内存估算与可行性
// ============================================================

enum MemoryEstimator {
    /// 权重 + 开销。开销是启发式：KV / 激活 / 框架常驻，按类别给不同的比例与下限。
    /// 一旦有实测峰值，直接用实测（权重字节仍然保证下限，防止实测是加载中读到的半截）。
    static func estimate(weightsGB: Double, category: ModelCategory, observedGB: Double?) -> (gb: Double, basis: String) {
        let overhead: Double
        switch category {
        case .chat:      overhead = max(2.0, weightsGB * 0.15)
        case .image:     overhead = max(2.0, weightsGB * 0.12)
        case .video:     overhead = max(3.0, weightsGB * 0.22)
        case .audio, .embedding: overhead = max(0.6, weightsGB * 0.10)
        case .part, .service, .other: overhead = 0
        }
        let est = weightsGB + overhead
        if let o = observedGB, o > est {
            return (o, String(format: "实测峰值 %.1f GB（本机跑过）", o))
        }
        if overhead > 0 {
            return (est, String(format: "权重 %.1f GB + 开销估算 %.1f GB", weightsGB, overhead))
        }
        return (est, String(format: "权重 %.1f GB", weightsGB))
    }
}

enum FitLevel {
    case comfortable, tight, insufficient, running, unavailable

    /// 只描述**内存**可行性；能不能真的拉起由按钮与提示行单独说明，
    /// 否则「未配置启动方式」的模型挂着「可拉起」绿药丸会自相矛盾。
    func text(canLaunch: Bool) -> String {
        switch self {
        case .comfortable:  return canLaunch ? "可拉起" : "内存够"
        case .tight:        return "勉强够"
        case .insufficient: return "内存不足"
        case .running:      return "运行中"
        case .unavailable:  return "不可单独起"
        }
    }
    var color: NSColor {
        switch self {
        case .comfortable:  return DS.green
        case .tight:        return DS.amber
        case .insufficient: return DS.red
        case .running:      return DS.blue
        case .unavailable:  return DS.inkTertiary
        }
    }
}

struct MemoryBudget {
    var totalGB: Double = 0
    var usedGB: Double = 0
    var reserveGB: Double = 6
    /// 口径拆分（拿得到就用新口径，拿不到回退到 total − used）
    var wiredGB: Double = 0          // 内核锁定，真正不可回收
    var compressedGB: Double = 0     // 压缩器占用
    var modelResidentGB: Double = 0  // 已驻留模型的 RSS

    /// 可用 = 总 − 唯一的「已用」 − 预留
    ///
    /// ⛔ 2026-10-31 实测：27B(27 GB) + H3-8bit(32 GB) 同驻时，wired 61 GB、模型 55.6 GB ——
    ///    模型的 Metal 页**同时**算进 wired 与「应用内存」，两者相加会超过物理内存，
    ///    旧公式给出「可用 0.0 GB」，而机器实际还有 4 GB 空闲页 + 65 GB 可回收缓存、压力 32%。
    ///    所以这里取 max(wired, 模型驻留) 而不是求和：同一批页只扣一次。
    var availableGB: Double {
        if wiredGB > 0 || compressedGB > 0 || modelResidentGB > 0 {
            return max(0, totalGB - max(wiredGB, modelResidentGB) - compressedGB - reserveGB)
        }
        return max(0, totalGB - usedGB - reserveGB)
    }

    static func fit(estGB: Double, budget: MemoryBudget) -> FitLevel {
        guard estGB > 0 else { return .unavailable }
        let a = budget.availableGB
        guard a > 0.5 else { return .insufficient }
        if estGB <= a * 0.85 { return .comfortable }
        if estGB <= a { return .tight }
        return .insufficient
    }
}

// ============================================================
// MARK: - 目录条目
// ============================================================

struct CatalogEntry {
    var id: String
    var title: String
    var subtitle: String
    var category: ModelCategory
    var diskGB: Double = 0
    var estMemGB: Double = 0
    var estBasis: String = ""
    var state: ModelState = .unregistered
    var memGB: Double = 0
    var port: Int? = nil
    var pid: pid_t? = nil
    var runtimeName: String = ""
    var engineName: String = ""       // 引擎显示名（Splash / ComfyUI …），界面不拿它跟模型名重复
    var recipe: LaunchRecipe? = nil
    var canLaunch: Bool = false
    var canStop: Bool = false
    var blockedReason: String? = nil
    var parts: [String] = []
    var diskPath: String? = nil
    /// 用户规则要求隐藏（折叠）时不进主列表；仍保留在清单里，可用「显示全部」看到
    var hidden: Bool = false
    /// 命中的规则来源（`--explain` 打印，便于用户调规则）
    var classifyEvidence: String = ""
    /// 数据里指定的归属引擎（托盘名），空则回落到配方/运行时自报
    var classifyEngine: String? = nil
}

enum ModelCatalog {
    /// 把磁盘单元 + 运行时快照 + 配方合成管理器要的清单。
    static func build(units: [DiskUnit], runtime: ModelSnapshot, config: LauncherConfig,
                      observed: ObservedMemory, roots: [String]) -> [CatalogEntry] {
        let rootSet = Set(roots.map { ($0 as NSString).resolvingSymlinksInPath })
        var entries: [CatalogEntry] = []
        var usedUnitIdx = Set<Int>()
        // 识别规则：每次 build 都从 registry.json 读盘（改数据即生效，无需重编译）
        let classifyData = ClassifyData.loadFromRegistry()

        // ---- 1) 把磁盘单元按「主模型目录」归组：部件（vae / text_encoder / 草稿头）跟着主模型算一家
        struct Group { var main: DiskUnit?; var parts: [DiskUnit] }
        var groups: [String: Group] = [:]
        var order: [String] = []
        // 归组键：同一模型目录下的「主权重 + 部件」算一家。
        // 两种真实布局都要覆盖：
        //   ① 主权重在 `<模型目录>/transformer`，部件在同级 `vae` / `text_encoder`；
        //   ② 主权重在 `<模型目录>/IQ3_S`，草稿头/投影在同级 `<模型目录>/mtp-*.gguf`。
        // 扫描根（`~/mlx-models` 这类）下面的散件不归组，否则整个根会变成一个「模型」。
        func keyFor(_ u: DiskUnit) -> String {
            let parent = (u.realPath as NSString).deletingLastPathComponent
            if rootSet.contains(parent) { return u.realPath }
            let siblings = units.filter {
                $0.realPath != u.realPath &&
                (($0.realPath as NSString).deletingLastPathComponent == parent)
            }
            guard !siblings.isEmpty else { return u.realPath }
            // 主权重这一层：只有同级真的有「部件」时才上提到父目录
            if u.identity.role == .main {
                return siblings.contains { $0.identity.role != .main } ? parent : u.realPath
            }
            // 部件这一层：同级有主权重就归过去
            return siblings.contains { $0.identity.role == .main } ? parent : u.realPath
        }
        for u in units {
            let k = keyFor(u)
            if groups[k] == nil { groups[k] = Group(main: nil, parts: []); order.append(k) }
            if u.identity.role == .main { groups[k]?.main = u } else { groups[k]?.parts.append(u) }
        }

        // ---- 2) 每个组 → 一条目录项（先按磁盘事实建，运行时与配方后置匹配）
        for k in order {
            guard let g = groups[k] else { continue }
            let primary = g.main ?? g.parts.first
            guard let p = primary else { continue }
            var diskBytes: Int64 = 0
            for u in ([g.main].compactMap { $0 } + g.parts) { diskBytes += u.identity.bytes }
            let weightsGB = Double(diskBytes) / 1_073_741_824
            var name = g.main?.identity.displayName ?? p.identity.displayName
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = ((k as NSString).lastPathComponent)
            }
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "未命名权重" }
            if g.main == nil, let first = g.parts.first, g.parts.count > 1 {
                name = first.identity.family ?? first.identity.displayName
            }
            let diskRole = g.main?.identity.role ?? p.identity.role
            let res = ModelClassifier.resolve(name: name, path: k, role: diskRole,
                                              categoryHint: nil, data: classifyData)
            let category = res.category ?? .chat
            let observedGB = observed.value(for: k)
            let est = MemoryEstimator.estimate(weightsGB: weightsGB, category: category, observedGB: observedGB)
            var entry = CatalogEntry(id: "disk:" + k, title: res.title ?? name,
                                     subtitle: p.source + " · " + abbreviate(k),
                                     category: category,
                                     diskGB: weightsGB, estMemGB: est.gb, estBasis: est.basis,
                                     diskPath: k)
            entry.hidden = res.hidden
            entry.classifyEngine = res.assignedEngine
            entry.classifyEvidence = res.evidence
            entry.parts = g.parts.map { $0.identity.displayName + "（" + $0.identity.role.rawValue + "）" }
            entries.append(entry)
            for (i, u) in units.enumerated() where u.realPath == g.main?.realPath || g.parts.contains(where: { $0.realPath == u.realPath }) {
                usedUnitIdx.insert(i)
            }
        }

        // ---- 3) 盘上没有、但配方声明了的模型（引擎从别处加载 / 用户手写配方）
        for r in config.recipes where r.kind != "service" {
            let already = entries.contains { e in
                if let rp = r.path, let dp = e.diskPath, realPathEqual(rp, dp) { return true }
                let hay = (e.title + " " + (e.diskPath ?? "")).lowercased()
                return r.modelPatterns.contains { !$0.isEmpty && hay.contains($0.lowercased()) }
            }
            guard !already else { continue }
            var weightsGB = 0.0
            if let p = r.path {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                    if isDir.boolValue, let id = ModelIdentifier.identify(path: p) {
                        weightsGB = Double(id.bytes) / 1_073_741_824
                    } else if let a = try? FileManager.default.attributesOfItem(atPath: p),
                              let n = a[.size] as? NSNumber {
                        weightsGB = n.doubleValue / 1_073_741_824
                    }
                }
            }
            let title = r.title ?? (r.path.map { ($0 as NSString).lastPathComponent } ?? r.id)
            let category = ModelClassifier.classify(name: title, path: r.path ?? "",
                                                    role: .main, categoryHint: r.category,
                                                    data: classifyData, engineFamily: r.engine, port: r.port)
            let observedGB = observed.value(for: r.path ?? r.id)
            let est = r.estMemGB.map { ($0, "配方声明") }
                ?? MemoryEstimator.estimate(weightsGB: weightsGB, category: category, observedGB: observedGB)
            var e = CatalogEntry(id: "recipe:" + r.id, title: title,
                                 subtitle: "配方 · " + (r.path.map(abbreviate) ?? r.id),
                                 category: category, diskGB: weightsGB,
                                 estMemGB: est.0, estBasis: est.1, diskPath: r.path)
            e.recipe = r
            entries.append(e)
        }

        // ---- 3b) 配方声明的「附件」（草稿头 / 视觉投影）并进主模型那一行：
        //          它们不可能单独拉起，单独占一行只会让用户以为还有一个模型。
        for r in config.recipes where !r.attachments.isEmpty {
            func matches(_ e: CatalogEntry, _ pat: String) -> Bool {
                let tail = ((e.diskPath ?? "") as NSString).lastPathComponent
                let hay = normName(e.title + " " + tail + " " + e.parts.joined(separator: " "))
                return hay.contains(normName(pat))
            }
            let hostIdx = entries.firstIndex(where: { e in
                if let rp = r.path, let dp = e.diskPath { return realPathEqual(rp, dp) }
                return false
            }) ?? entries.firstIndex(where: { isEntry($0, for: r) })
            guard let hostIdx = hostIdx else { continue }
            var host = entries[hostIdx]
            var remove: [Int] = []
            for (i, e) in entries.enumerated() where i != hostIdx {
                guard r.attachments.contains(where: { matches(e, $0) }) else { continue }
                host.diskGB += e.diskGB
                if host.recipe?.estMemGB == nil || r.estMemGB == nil { host.estMemGB += e.estMemGB }
                host.parts.append(e.title)
                remove.append(i)
            }
            entries[hostIdx] = host
            for i in remove.sorted(by: >) { entries.remove(at: i) }
        }

        // ---- 4) 服务类配方（ComfyUI / 引擎守护进程）：单独一行，可启停
        for r in config.recipes where r.kind == "service" {
            let title = r.title ?? r.id
            var e = CatalogEntry(id: "recipe:" + r.id, title: title,
                                 subtitle: "服务 · " + (r.path.map(abbreviate) ?? "端口 \(r.port ?? 0)"),
                                 category: .service, diskGB: 0,
                                 estMemGB: r.estMemGB ?? 0, estBasis: r.estMemGB == nil ? "按需加载" : "配方声明",
                                 diskPath: r.path)
            e.recipe = r
            entries.append(e)
        }

        // ---- 5) 运行时匹配：状态 / 端口 / 内存 / 引擎
        // 打分：配方认得它（5）> 名字全等（4）> 目录名对得上（3）> 名字互相包含且够长（2）。
        // 2 分以下的「像」一律不算 —— 实测会把 Strata 的运行实例挂到 strata-data 这种目录上。
        var matchedEntries = Set<Int>()
        for row in runtime.rows {
            var bestIdx: Int? = nil
            var bestScore = 0
            for (i, e) in entries.enumerated() where !matchedEntries.contains(i) {
                let sc = runtimeMatchScore(row: row, entry: e, config: config)
                if sc > bestScore { bestScore = sc; bestIdx = i }
            }
            guard let i = bestIdx, bestScore >= 2 else { continue }
            matchedEntries.insert(i)
            entries[i].state = row.state
            entries[i].memGB = row.memGB
            entries[i].port = row.port
            entries[i].pid = row.pid
            entries[i].runtimeName = row.name
            entries[i].engineName = row.engine
            if let p = entries[i].diskPath { observed.note(key: p, memGB: row.memGB) }
            else { observed.note(key: entries[i].id, memGB: row.memGB) }
        }

        // ---- 6) 运行时里有、盘上/配方里都没有的（自定义端口、应用内模型）也列出来，否则没法卸
        for row in runtime.rows {
            let already = entries.contains { $0.runtimeName == row.name && $0.port == row.port }
            guard !already else { continue }
            let cat = ModelClassifier.classify(name: row.name, path: row.note, role: .main,
                                               categoryHint: nil, data: classifyData,
                                               engineFamily: row.engine, port: row.port)
            var e = CatalogEntry(id: "runtime:\(row.port ?? 0):\(row.name)", title: row.name,
                                 subtitle: "运行时 · " + (row.note.split(separator: "·").first.map(String.init) ?? "引擎自报"),
                                 category: cat, estMemGB: row.memGB, estBasis: "当前实测")
            e.state = row.state
            e.memGB = row.memGB
            e.port = row.port
            e.pid = row.pid
            e.runtimeName = row.name
            entries.append(e)
        }

        // ---- 6b) 去重（D18 · 2026-10-31）：同一份权重 / 同一个端口只出一张卡
        //  ① HF 缓存里的副本：`~/.cache/huggingface/hub/models--org--name` 与用户目录那份是同一个模型。
        //     单独成卡会让用户读成「又拉起了一个 27B」（实测：脚本误下载一份 27B，界面立刻多一张卡）。
        //  ② 同一端口上的两个运行条目：只可能是一个东西的两种叫法，留带配方的那张。
        var dropIdx = Set<Int>()
        for i in entries.indices where !dropIdx.contains(i) {
            let e = entries[i]
            guard e.subtitle.contains("HF 缓存") else { continue }
            let key = normName(e.title)
            guard key.count >= 6,
                  let host = entries.indices.first(where: { j in
                      j != i && !dropIdx.contains(j) && !entries[j].subtitle.contains("HF 缓存")
                          && normName(entries[j].title) == key
                  }) else { continue }
            entries[host].diskGB += e.diskGB
            entries[host].parts.append("HF 缓存副本")
            dropIdx.insert(i)
        }
        for i in entries.indices where !dropIdx.contains(i) {
            guard let port = entries[i].port,
                  [.running, .loading, .idle].contains(entries[i].state) else { continue }
            guard let j = entries.indices.first(where: { j in
                j != i && !dropIdx.contains(j) && entries[j].port == port
                    && [.running, .loading, .idle].contains(entries[j].state)
            }) else { continue }
            let keepI = entries[i].recipe != nil || entries[j].recipe == nil
            let keep = keepI ? i : j
            let drop = keepI ? j : i
            entries[keep].parts.append("同端口另一实例：" + entries[drop].title)
            if entries[keep].memGB == 0 { entries[keep].memGB = entries[drop].memGB }
            dropIdx.insert(drop)
        }
        if !dropIdx.isEmpty {
            entries = entries.enumerated().filter { !dropIdx.contains($0.offset) }.map { $0.element }
        }

        // ---- 7) 配方 / 可启动性
        for i in entries.indices {
            var e = entries[i]
            if e.recipe == nil {
                // 先用「盘上那个名字」找，再用引擎自报的名字找；都带上引擎与端口
                // （运行时行常见只有引擎自报的 id，和目录名对不上，但引擎+端口是唯一的）
                let engine = e.engineName.isEmpty ? nil : e.engineName
                for candidate in [e.title, e.runtimeName] where !candidate.isEmpty {
                    if let r = config.recipe(forName: candidate, path: e.diskPath,
                                             engine: engine, port: e.port) {
                        e.recipe = r
                        break
                    }
                }
            }
            let running = [.running, .loading, .idle].contains(e.state)
            // 「卸载」只对**真的在内存里**的模型有意义：有停止配方不等于它现在正跑着。
            // 之前写成 `canStop = r.stop != nil || running`，没拉起的模型也挂了可点的「卸载」（用户抓到）。
            if let r = e.recipe {
                e.canLaunch = r.start != nil && !running
                e.canStop = running && (r.stop != nil || e.pid != nil)
                if r.start == nil && !running { e.blockedReason = "配方没有 start 命令" }
                if running && r.stop == nil {
                    e.blockedReason = e.pid != nil
                        ? "配方没有 stop 命令：只能结束进程（pid \(e.pid ?? 0)）"
                        : "配方没有 stop 命令"
                }
                // 配方声明优先于启发式：MoE + mmap 的模型权重不等于常驻（125B 的 78 GB 文件只驻 18 GB），
                // 只有写配方的人知道这台机器上它到底占多少。
                if let declared = r.estMemGB, declared > 0 {
                    e.estMemGB = declared
                    e.estBasis = "配方声明"
                }
                if e.category == .chat, let c = r.category, let mc = ModelCategory(rawValue: c.lowercased()) {
                    e.category = mc
                }
            } else if let adapter = BuiltinAdapters.adapter(for: e) {
                e.canLaunch = adapter.canLaunch && !running
                e.canStop = running && (adapter.canUnload || e.pid != nil)
                e.blockedReason = e.canLaunch || running ? nil : adapter.reason
            } else {
                e.canLaunch = false
                e.canStop = running && e.pid != nil
                e.blockedReason = running
                    ? "没有停止配方：只能结束进程（pid \(e.pid ?? 0)）"
                    : "未配置启动方式（在 registry.json 的 recipes 里加一条配方）"
            }
            if e.category == .part && !running {
                e.canLaunch = false
                e.blockedReason = "部件随主模型一起加载，不能单独拉起"
            }
            entries[i] = e
        }

        entries.sort { a, b in
            let rank: (ModelState) -> Int = { s in
                switch s {
                case .running: return 0
                case .loading: return 1
                case .idle: return 2
                case .failed: return 3
                case .uncertain: return 4
                case .unregistered, .unloaded: return 5
                }
            }
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            if a.category.order != b.category.order { return a.category.order < b.category.order }
            return a.estMemGB > b.estMemGB
        }
        return entries
    }

    /// 运行时行 ↔ 目录条目 的匹配打分（见步骤 5 的说明）
    private static func runtimeMatchScore(row: ModelRow, entry e: CatalogEntry,
                                          config: LauncherConfig) -> Int {
        if let r = config.recipes.first(where: {
            // 服务配方（ComfyUI 这类）也要能认领自己的运行行，否则管理器里会出两张卡：
            // 「配方 · 未运行」+「运行时 · 运行中」。`isEntry` 仍然要求路径/模式对上，
            // 不会让服务配方把别的模型抢走。
            $0.matches(name: row.name, path: nil, engine: row.engine, port: row.port)
        }), isEntry(e, for: r) {
            return 5
        }
        let a = normName(row.name)
        let title = normName(e.title)
        if !a.isEmpty, a == title { return 4 }
        if let p = e.diskPath {
            let base = normName((p as NSString).lastPathComponent)
            if !a.isEmpty, a == base { return 3 }
        }
        if min(a.count, title.count) >= 8, a.contains(title) || title.contains(a) { return 2 }
        return 0
    }

    /// 这条目录项是不是某条配方要找的那个模型（路径相等，或标题/目录名命中模式）
    private static func isEntry(_ e: CatalogEntry, for r: LaunchRecipe) -> Bool {
        if let rp = r.path, let dp = e.diskPath, realPathEqual(rp, dp) { return true }
        let tail = ((e.diskPath ?? "") as NSString).lastPathComponent
        let hay = normName(e.title + " " + tail)
        return r.modelPatterns.contains { !$0.isEmpty && hay.contains(normName($0)) }
    }

    private static func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":latest", with: "")
    }
}

private func abbreviate(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

// ============================================================
// MARK: - 内置适配器（没有配方也能启停的两家）
// ============================================================

enum BuiltinAdapters {
    struct Adapter {
        var kind: String
        var canLaunch: Bool
        var canUnload: Bool
        var reason: String?
        var modelID: String
        var port: Int
    }

    static func adapter(for e: CatalogEntry) -> Adapter? {
        let hay = (e.title + " " + e.subtitle).lowercased()
        let running = [ModelState.running, .idle, .loading].contains(e.state)
        if hay.contains("ollama"), let port = e.port ?? Optional(11434) {
            // Ollama 的模型 id 就是条目名（manifest 名字里带 :tag）
            let id = e.runtimeName.isEmpty ? e.title : e.runtimeName
            return Adapter(kind: "ollama", canLaunch: true, canUnload: true, reason: nil,
                           modelID: id, port: port)
        }
        if hay.contains("lm studio"), let port = e.port ?? Optional(1234) {
            let id = e.diskPath ?? e.runtimeName
            let hasCLI = LMStudioCLI.path != nil
            return Adapter(kind: "lmstudio", canLaunch: hasCLI, canUnload: hasCLI,
                           reason: hasCLI ? nil : "没找到 lms 命令行工具",
                           modelID: id, port: port)
        }
        _ = running
        return nil
    }
}

enum LMStudioCLI {
    static var path: String? {
        let candidates = ["/opt/homebrew/bin/lms", "/usr/local/bin/lms",
                          NSHomeDirectory() + "/.lmstudio/bin/lms",
                          NSHomeDirectory() + "/.cache/lm-studio/bin/lms"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ args: [String]) -> (code: Int32, output: String) {
        guard let bin = path else { return (-1, "没有 lms") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// ============================================================
// MARK: - 动作执行（拉起 / 卸载 / 工作组）
// ============================================================

final class ModelActionRunner {
    enum Phase: Equatable {
        case idle
        case launching(Date)
        case stopping(Date)
        case failed(String)

        var isBusy: Bool {
            switch self { case .launching, .stopping: return true; default: return false }
        }
    }

    struct State {
        var phase: Phase = .idle
        var detail: String = ""
        var finishedAt: Date? = nil
    }

    private var states: [String: State] = [:]
    private let queue = DispatchQueue(label: "io.github.autugit.dockolate.actions", qos: .userInitiated)
    /// 动作完成后通知界面（主线程）
    var onChange: (() -> Void)?

    private static var logDir: String {
        NSHomeDirectory() + "/Library/Logs/Dockolate"
    }

    func state(for id: String) -> State? { states[id] }
    func isBusy(_ id: String) -> Bool { states[id]?.phase.isBusy ?? false }

    private func set(_ id: String, _ s: State) {
        DispatchQueue.main.async {
            self.states[id] = s
            self.onChange?()
        }
    }

    private func appendLog(_ id: String, _ text: String) {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        let path = ModelActionRunner.logDir + "/action-\(safe).log"
        try? FileManager.default.createDirectory(atPath: ModelActionRunner.logDir, withIntermediateDirectories: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(stamp)] \(text)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // ---------- 拉起 ----------
    func launch(_ entry: CatalogEntry) {
        guard !isBusy(entry.id) else { return }
        if let recipe = entry.recipe, let cmd = recipe.start {
            set(entry.id, State(phase: .launching(Date()), detail: "启动命令已发出"))
            appendLog(entry.id, "== launch (recipe \(recipe.id)) ==\n" + cmd.display)
            queue.async { [weak self] in
                guard let self = self else { return }
                let r = self.startAndWait(cmd, id: entry.id, port: recipe.port, timeout: recipe.readyTimeoutSec)
                // 2026-11-02：结果必须落进 action 日志。此前只记 "spawned pid"，launcher 以非 0 退出
                // （如内存闸门 return 7）时日志里没有任何痕迹，用户看到的就是「点了没反应」。
                self.appendLog(entry.id, (r.ok ? "✓ " : "✗ ") + r.message
                               + (r.output.isEmpty ? "" : "\n" + r.output))
                self.set(entry.id, State(phase: r.ok ? .idle : .failed(r.message),
                                         detail: r.ok ? r.message : r.output, finishedAt: Date()))
            }
            return
        }
        if let adapter = BuiltinAdapters.adapter(for: entry) {
            guard adapter.canLaunch else {
                set(entry.id, State(phase: .failed(adapter.reason ?? "不可拉起")))
                return
            }
            set(entry.id, State(phase: .launching(Date()), detail: "请求引擎加载"))
            queue.async { [weak self] in
                guard let self = self else { return }
                switch adapter.kind {
                case "ollama":
                    let body: [String: Any] = ["model": adapter.modelID, "prompt": "", "keep_alive": -1, "stream": false]
                    let ok = LocalHTTP.postJSON(port: adapter.port, path: "/api/generate", json: body) != nil
                    self.set(entry.id, ok
                             ? State(phase: .idle, detail: "Ollama 已加载 \(adapter.modelID)", finishedAt: Date())
                             : State(phase: .failed("Ollama 没接受加载请求"), finishedAt: Date()))
                case "lmstudio":
                    let r = LMStudioCLI.run(["load", adapter.modelID])
                    self.set(entry.id, r.code == 0
                             ? State(phase: .idle, detail: "LM Studio 已加载", finishedAt: Date())
                             : State(phase: .failed("lms load 退出码 \(r.code)"), detail: self.tail(r.output), finishedAt: Date()))
                default:
                    self.set(entry.id, State(phase: .failed("不支持的内置适配器")))
                }
            }
            return
        }
        set(entry.id, State(phase: .failed("没有启动方式")))
    }

    // ---------- 卸载 ----------
    func stop(_ entry: CatalogEntry) {
        guard !isBusy(entry.id) else { return }
        if let recipe = entry.recipe, let cmd = recipe.stop {
            set(entry.id, State(phase: .stopping(Date()), detail: "停止命令已发出"))
            appendLog(entry.id, "== stop (recipe \(recipe.id)) ==\n" + cmd.display)
            queue.async { [weak self] in
                guard let self = self else { return }
                let cfg = LauncherConfig.load()
                let baseline = ReleaseGate.availableGB(reserveGB: cfg.reserveGB)
                let r = self.runCommand(cmd, id: entry.id, timeout: 90)
                var released = true
                var gateNote = ""
                if let port = recipe.port {
                    released = ReleaseGate.waitPortFree(port, timeout: 45)
                    if released {
                        // M1b：端口释放 ≠ 内存回来。再等进程树与可用内存到位。
                        let gate = ReleaseGate.waitMemory(atLeast: entry.estMemGB + cfg.reserveGB,
                                                          expectGB: entry.estMemGB,
                                                          baselineGB: baseline,
                                                          reserveGB: cfg.reserveGB,
                                                          timeout: 90)
                        gateNote = String(format: " · 回收 %.1f GB / %.0f s", gate.freedGB, gate.seconds)
                        if !gate.ok { gateNote += "（\(gate.detail)）" }
                        self.appendLog(entry.id, String(format: "release: %@ freed=%.1fGB %.1fs",
                                                        gate.detail, gate.freedGB, gate.seconds))
                    }
                }
                self.appendLog(entry.id, (r.code == 0 && released)
                               ? "✓ 停止完成（退出码 0，端口已释放）"
                               : "✗ 停止未完成：退出码 \(r.code)，端口释放=\(released)")
                if r.code == 0 && released {
                    self.set(entry.id, State(phase: .idle,
                                             detail: (recipe.port.map { "已卸载（端口 \($0) 已释放）" } ?? "停止命令已完成") + gateNote,
                                             finishedAt: Date()))
                } else {
                    self.set(entry.id, State(phase: .failed(released ? "停止命令退出码 \(r.code)" : "端口仍在监听"),
                                             detail: self.tail(r.output), finishedAt: Date()))
                }
            }
            return
        }
        if let adapter = BuiltinAdapters.adapter(for: entry), adapter.canUnload {
            set(entry.id, State(phase: .stopping(Date()), detail: "请求引擎卸载"))
            queue.async { [weak self] in
                guard let self = self else { return }
                switch adapter.kind {
                case "ollama":
                    let body: [String: Any] = ["model": adapter.modelID, "prompt": "", "keep_alive": 0, "stream": false]
                    let ok = LocalHTTP.postJSON(port: adapter.port, path: "/api/generate", json: body) != nil
                    self.set(entry.id, ok
                             ? State(phase: .idle, detail: "Ollama 已卸载", finishedAt: Date())
                             : State(phase: .failed("Ollama 没接受卸载请求"), finishedAt: Date()))
                case "lmstudio":
                    let r = LMStudioCLI.run(["unload", adapter.modelID])
                    self.set(entry.id, r.code == 0
                             ? State(phase: .idle, detail: "LM Studio 已卸载", finishedAt: Date())
                             : State(phase: .failed("lms unload 退出码 \(r.code)"), detail: self.tail(r.output), finishedAt: Date()))
                default:
                    self.set(entry.id, State(phase: .failed("不支持的内置适配器")))
                }
            }
            return
        }
        if let pid = entry.pid {
            set(entry.id, State(phase: .stopping(Date()), detail: "结束进程 \(pid)"))
            queue.async { [weak self] in
                kill(pid, SIGTERM)
                var ok = false
                for _ in 0..<60 {
                    if kill(pid, 0) != 0 { ok = true; break }
                    usleep(500_000)
                }
                if !ok { kill(pid, SIGKILL); usleep(500_000) }
                self?.set(entry.id, State(phase: ok ? .idle : .failed("进程没退出（已发送 SIGKILL）"),
                                          detail: "", finishedAt: Date()))
            }
            return
        }
        set(entry.id, State(phase: .failed("没有卸载方式")))
    }

    // ---------- 工作组 ----------
    func launchGroup(_ group: Workgroup, entries: [CatalogEntry]) {
        let members = group.members.compactMap { id in entries.first { $0.id == id } }
        let groupID = "group:" + group.id
        set(groupID, State(phase: .launching(Date()), detail: "启动 \(members.count) 个成员"))
        queue.async { [weak self] in
            guard let self = self else { return }
            var ok = 0
            var fail: [String] = []
            for m in members {
                if self.launchBlocking(m) { ok += 1 } else { fail.append(m.title) }
            }
            self.set(groupID, State(phase: fail.isEmpty ? .idle : .failed("\(fail.count) 个成员失败"),
                                    detail: fail.isEmpty ? "已启动 \(ok) 个" : fail.joined(separator: "、"),
                                    finishedAt: Date()))
        }
    }

    func stopGroup(_ group: Workgroup, entries: [CatalogEntry]) {
        let members = group.members.compactMap { id in entries.first { $0.id == id } }
        let groupID = "group:" + group.id
        set(groupID, State(phase: .stopping(Date()), detail: "停止 \(members.count) 个成员"))
        queue.async { [weak self] in
            guard let self = self else { return }
            for m in members.reversed() { self.stopBlocking(m) }
            self.set(groupID, State(phase: .idle, detail: "已停止", finishedAt: Date()))
        }
    }

    /// 同步版拉起（供工作组顺序执行）。返回是否成功。
    @discardableResult
    private func launchBlocking(_ entry: CatalogEntry) -> Bool {
        if let recipe = entry.recipe, let cmd = recipe.start {
            set(entry.id, State(phase: .launching(Date()), detail: "启动命令已发出"))
            let r = startAndWait(cmd, id: entry.id, port: recipe.port, timeout: recipe.readyTimeoutSec)
            set(entry.id, State(phase: r.ok ? .idle : .failed(r.message),
                                detail: r.ok ? r.message : r.output, finishedAt: Date()))
            return r.ok
        }
        if let adapter = BuiltinAdapters.adapter(for: entry), adapter.canLaunch {
            switch adapter.kind {
            case "ollama":
                let body: [String: Any] = ["model": adapter.modelID, "prompt": "", "keep_alive": -1, "stream": false]
                let ok = LocalHTTP.postJSON(port: adapter.port, path: "/api/generate", json: body) != nil
                set(entry.id, State(phase: ok ? .idle : .failed("Ollama 没接受加载请求"), finishedAt: Date()))
                return ok
            case "lmstudio":
                let r = LMStudioCLI.run(["load", adapter.modelID])
                set(entry.id, State(phase: r.code == 0 ? .idle : .failed("lms load 退出码 \(r.code)"), finishedAt: Date()))
                return r.code == 0
            default: break
            }
        }
        set(entry.id, State(phase: .failed(entry.blockedReason ?? "没有启动方式")))
        return false
    }

    private func stopBlocking(_ entry: CatalogEntry) {
        if let recipe = entry.recipe, let cmd = recipe.stop {
            set(entry.id, State(phase: .stopping(Date()), detail: "停止命令已发出"))
            let cfg = LauncherConfig.load()
            let baseline = ReleaseGate.availableGB(reserveGB: cfg.reserveGB)
            let r = runCommand(cmd, id: entry.id, timeout: 90)
            var gateNote = ""
            if let port = recipe.port, ReleaseGate.waitPortFree(port, timeout: 45) {
                let gate = ReleaseGate.waitMemory(atLeast: entry.estMemGB + cfg.reserveGB,
                                                  expectGB: entry.estMemGB,
                                                  baselineGB: baseline,
                                                  reserveGB: cfg.reserveGB,
                                                  timeout: 90)
                gateNote = String(format: " · 回收 %.1f GB / %.0f s", gate.freedGB, gate.seconds)
                if !gate.ok { gateNote += "（\(gate.detail)）" }
            }
            set(entry.id, State(phase: r.code == 0 ? .idle : .failed("停止命令退出码 \(r.code)"),
                                detail: gateNote, finishedAt: Date()))
            return
        }
        if let adapter = BuiltinAdapters.adapter(for: entry), adapter.canUnload {
            switch adapter.kind {
            case "ollama":
                let body: [String: Any] = ["model": adapter.modelID, "prompt": "", "keep_alive": 0, "stream": false]
                _ = LocalHTTP.postJSON(port: adapter.port, path: "/api/generate", json: body)
            case "lmstudio":
                _ = LMStudioCLI.run(["unload", adapter.modelID])
            default: break
            }
            set(entry.id, State(phase: .idle, detail: "已卸载", finishedAt: Date()))
            return
        }
        if let pid = entry.pid {
            kill(pid, SIGTERM)
            for _ in 0..<40 { if kill(pid, 0) != 0 { break }; usleep(250_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            set(entry.id, State(phase: .idle, detail: "已结束进程", finishedAt: Date()))
        }
    }

    // ---------- 子进程 ----------
    /// 拉起一个**可能常驻**的启动命令：
    ///   · 端口就绪即成功（llama.cpp / ComfyUI 这类服务会一直不退出）；
    ///   · 命令提前退出：非 0 ⇒ 失败；0 且无端口声明 ⇒ 成功；0 但有端口 ⇒ 继续等端口；
    ///   · 超时 ⇒ 失败，并杀掉还没退出的子进程（不留孤儿）。
    private func startAndWait(_ cmd: CommandSpec, id: String, port: Int?,
                              timeout: Double) -> (ok: Bool, message: String, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.argv[0])
        p.arguments = Array(cmd.argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["NO_PROXY"] = "127.0.0.1,localhost,::1"
        env["no_proxy"] = "127.0.0.1,localhost,::1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        final class Sink {
            var data = Data()
            let lock = NSLock()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func text() -> String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
        }
        let sink = Sink()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            sink.append(d)
        }
        do { try p.run() } catch {
            return (false, "无法执行：\(error.localizedDescription)", "")
        }
        appendLog(id, "spawned pid \(p.processIdentifier): \(cmd.display)")

        let deadline = Date().addingTimeInterval(max(5, timeout))
        var exitedCleanly = false
        while Date() < deadline {
            if let port = port, LocalHTTP.connectable(port: port, timeoutMs: 300) {
                pipe.fileHandleForReading.readabilityHandler = nil
                return (true, "已拉起（端口 \(port) 就绪）", tail(sink.text()))
            }
            if !p.isRunning && !exitedCleanly {
                let code = p.terminationStatus
                if code != 0 {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    return (false, "启动命令退出码 \(code)", tail(sink.text()))
                }
                exitedCleanly = true
                if port == nil {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    return (true, "启动命令已完成", tail(sink.text()))
                }
                // 命令成功退出但端口还没开：启动脚本把服务丢到后台了（ComfyUI 的 launcher 就是这样），
                // 继续等端口到超时为止 —— 不能只等 15 秒，ComfyUI 冷启要几十秒。
            }
            usleep(400_000)
        }
        if let port = port {
            if LocalHTTP.connectable(port: port, timeoutMs: 300) {
                pipe.fileHandleForReading.readabilityHandler = nil
                return (true, "已拉起（端口 \(port) 就绪）", tail(sink.text()))
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            return (false, "端口 \(port) 在 \(Int(timeout)) 秒内没就绪", tail(sink.text()))
        }
        if p.isRunning { p.terminate() }
        pipe.fileHandleForReading.readabilityHandler = nil
        return (false, "启动命令在 \(Int(timeout)) 秒内没有结束", tail(sink.text()))
    }

    /// 跑一条**短命令**（停止 / pkill 这类），带超时保护
    private func runCommand(_ cmd: CommandSpec, id: String, timeout: Double = 60) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.argv[0])
        p.arguments = Array(cmd.argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["NO_PROXY"] = "127.0.0.1,localhost,::1"
        env["no_proxy"] = "127.0.0.1,localhost,::1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return (-1, "无法执行：\(error.localizedDescription)")
        }
        var out = Data()
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let d = handle.availableData
            if d.isEmpty { break }              // EOF：子进程关闭了管道
            out.append(d)
            appendLog(id, String(decoding: d, as: UTF8.self))
            if !p.isRunning { break }
        }
        if p.isRunning {
            p.terminate()
            usleep(500_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        // 把管道里剩下的读干净
        if let rest = try? handle.readToEnd(), !rest.isEmpty { out.append(rest) }
        return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
    }

    /// 等端口就绪 / 释放
    private func waitPort(_ port: Int, up: Bool, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(max(1, timeout))
        while Date() < deadline {
            let now = LocalHTTP.connectable(port: port, timeoutMs: 250)
            if now == up { return true }
            usleep(500_000)
        }
        return LocalHTTP.connectable(port: port, timeoutMs: 250) == up
    }

    private func tail(_ s: String, lines: Int = 6) -> String {
        let arr = s.split(separator: "\n").suffix(lines)
        return arr.joined(separator: "\n")
    }

    /// 清理过期状态（成功/失败都保留 6 秒给界面看，之后回到 idle）
    func pruneOldStates() {
        let now = Date()
        for (id, s) in states {
            guard let t = s.finishedAt, now.timeIntervalSince(t) > 6 else { continue }
            DispatchQueue.main.async { self.states[id] = nil }
        }
    }
}
