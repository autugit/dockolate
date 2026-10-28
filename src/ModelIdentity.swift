// ============================================================
// 模型身份层（方案 M2）
// ============================================================
//
// 目的：把「引擎说它叫什么」升级成「引擎说叫什么 + 文件里写的是什么」。
// 只读**文件头**（GGUF 头部 KV / safetensors 的 JSON 头 / config.json），不扫全文件。
//
// 为什么不能只靠名字：同一家族的 4bit / 8bit / IQ3 / IQ4 命名各引擎不一致；
// 而配置文件与文件头里的信息是结构化的、跨引擎一致的。
//
// 角色（role）的判据，按可靠性排序：
//   1. GGUF 的 `general.architecture` 后缀（`… -mtp` 是草稿头）
//   2. 文件名里的稳定性关键字（mmproj / mtp / lora / vae / text_encoder）
//   3. 目录名（ComfyUI 的 checkpoints / loras / vae / text_encoders）
//   4. 其它 ⇒ main（主权重）

import Foundation

enum ModelRole: String {
    case main        = "主权重"
    case mtp         = "草稿头"
    case projector   = "视觉投影"
    case lora        = "LoRA"
    case vae         = "VAE"
    case textEncoder = "文本编码器"
    case other       = "其它"
}

struct ModelIdentity {
    var family: String?          // 架构 / 模型名（如 Qwen3.8-Flash-Next）
    var architecture: String?     // config 的 model_type 或 GGUF 的 general.architecture
    var quant: String?            // 量化描述（Q8_0 / IQ3_S / 4bit gs64 …）
    var format: String?           // gguf / mlx / safetensors / 未知
    var role: ModelRole = .main
    var bytes: Int64 = 0          // 权重文件合计（在盘字节）
    var files: Int = 0            // 权重文件个数
    /// 去重键：最大权重文件的 `dev:ino`。硬链接副本（同一 inode）与符号链接（realpath 相同）
    /// 都靠它折叠成一条 —— 只按路径去重会把「同一份字节的另一个名字」算两遍。
    var inodeKey: String? = nil
    /// 是否有「这就是模型权重」的正面证据：config.json / GGUF 魔数 / safetensors 头。
    /// 光有 .bin 不算（例如推理引擎的专家包），否则清单里会混进非模型的大文件。
    var hasModelEvidence = false

    /// 界面用的短名：有家族就写家族，再带量化与角色标记
    var displayName: String {
        var parts: [String] = []
        let fam = family ?? "未命名权重"
        parts.append(fam)
        // 目录名里常常已经写着量化（xxx-8bit / xxx-IQ3_S），别重复一遍
        if let q = quant, !fam.lowercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "").contains(q.lowercased().replacingOccurrences(of: " ", with: "")) {
            parts.append(q)
        }
        if role != .main { parts.append(role.rawValue) }
        return parts.joined(separator: " · ")
    }
}

// ============================================================
// MARK: - GGUF 头部读取
// ============================================================
//
// 只读前 8 MB 到一个缓冲区里解析（tokenizer 那种巨型数组通常排在 general.* 之后，
// 撞到缓冲区边界就停，已经拿到的键足够识别身份）。

enum GGUFHead {
    struct Info {
        var version: Int = 0
        var tensorCount: Int = 0
        var kv: [String: String] = [:]      // 只保留标量/短字符串，数组只记元素数
        var arrayCounts: [String: Int] = [:]
    }

    static func read(path: String, window: Int = 8 << 20) -> Info? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: window), head.count > 32 else { return nil }
        guard head.starts(with: Array("GGUF".utf8)) else { return nil }

        let d = [UInt8](head)
        var p = 4
        func u8() -> UInt8? { p + 1 <= d.count ? d[p] : nil }
        func u32() -> UInt32? {
            guard p + 4 <= d.count else { return nil }
            let v = UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16 | UInt32(d[p + 3]) << 24
            p += 4
            return v
        }
        func u64() -> UInt64? {
            guard p + 8 <= d.count else { return nil }
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = v << 8 | UInt64(d[p + i]) }
            p += 8
            return v
        }
        func skip(_ n: Int) -> Bool {
            guard n >= 0, p + n <= d.count else { return false }
            p += n
            return true
        }
        func str() -> String? {
            guard let n = u64(), n <= 1 << 20, Int(n) <= d.count - p else { return nil }
            let s = String(decoding: d[p..<p + Int(n)], as: UTF8.self)
            p += Int(n)
            return s
        }
        /// 读取任意类型的值；返回可显示的字符串（数组返回 nil，只推进游标）
        func value(_ type: UInt32, depth: Int = 0) -> String? {
            switch type {
            case 0: return u8().map { "\($0)" }
            case 1: if let b = u8() { return "\(Int8(bitPattern: b))" }; return nil
            case 2: if let v = u32() { return "\(UInt16(truncatingIfNeeded: v))" }; return nil
            case 3: if let v = u32() { return "\(Int16(truncatingIfNeeded: v))" }; return nil
            case 4: return u32().map { "\($0)" }
            case 5: if let v = u32() { return "\(Int32(bitPattern: v))" }; return nil
            case 6: guard let v = u32() else { return nil }; return "\(Float(bitPattern: v))"
            case 7: return u8().map { $0 == 0 ? "false" : "true" }
            case 8: return str()
            case 10: return u64().map { "\($0)" }
            case 11: if let v = u64() { return "\(Int64(bitPattern: v))" }; return nil
            case 12: guard let v = u64() else { return nil }; return "\(Double(bitPattern: v))"
            case 9:   // 数组：只为推进游标，不保留内容
                guard depth < 4, let et = u32(), var n = u64() else { return nil }
                while n > 0 {
                    guard value(et, depth: depth + 1) != nil || et == 9 else { return nil }
                    if et == 9 { guard value(9, depth: depth + 1) != nil else { return nil } }
                    n -= 1
                }
                return nil
            default: return nil
            }
        }

        var info = Info()
        info.version = Int(u32() ?? 0)
        info.tensorCount = Int(u64() ?? 0)
        let kvCount = Int(min(u64() ?? 0, 4096))
        for _ in 0..<kvCount {
            guard let key = str() else { break }
            guard let type = u32() else { break }
            let before = p
            if type == 9 {
                // 数组：先读元素类型与个数，元素内容只推进游标；记下个数后跳过
                guard let et = u32(), let n = u64() else { break }
                info.arrayCounts[key] = Int(n)
                var remaining = n
                var ok = true
                while remaining > 0 {
                    if value(et, depth: 1) == nil && et != 9 { ok = false; break }
                    remaining -= 1
                }
                if !ok { p = before; break }
            } else if let s = value(type) {
                info.kv[key] = s
            } else {
                break
            }
        }
        return info
    }
}

// ============================================================
// MARK: - 身份识别
// ============================================================

enum ModelIdentifier {
    // 常见量化标签（GGUF 家族）：文件名里靠这些词识得更稳
    private static let quantWords = ["IQ1_S", "IQ1_M", "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M",
                                     "IQ3_XXS", "IQ3_XS", "IQ3_S", "IQ3_M",
                                     "IQ4_XS", "IQ4_NL", "Q2_K", "Q2_K_S", "Q3_K_S", "Q3_K_M", "Q3_K_L",
                                     "Q4_K_S", "Q4_K_M", "Q4_K_L", "Q4_0", "Q4_1", "Q5_K_S", "Q5_K_M",
                                     "Q5_0", "Q5_1", "Q6_K", "Q8_0", "BF16", "F16", "F32"]
    /// 权重文件扩展名（清单层也要用，故公开）
    static let weightExtsPublic = [".safetensors", ".gguf", ".bin", ".ckpt", ".pt", ".pth"]
    private static let weightExts = weightExtsPublic

    /// 识别一个**目录**（HF 快照 / MLX 目录 / ComfyUI 子目录 / 用户目录）或单个权重文件
    static func identify(path: String) -> ModelIdentity? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? identifyDirectory(path) : identifyFile(path)
    }

    // ---------- 单文件（GGUF / safetensors） ----------
    static func identifyFile(_ path: String) -> ModelIdentity? {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        var id = ModelIdentity()
        id.files = 1
        id.bytes = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value ?? 0)
        id.role = roleFromName(lower, parent: ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased())

        id.inodeKey = Self.inodeKey(path)
        id.hasModelEvidence = lower.hasSuffix(".gguf") || lower.hasSuffix(".safetensors") || lower.hasSuffix(".ckpt")

        if lower.hasSuffix(".gguf"), let head = GGUFHead.read(path: path) {
            id.format = "gguf"
            id.architecture = head.kv["general.architecture"]
            id.family = head.kv["general.name"] ?? head.kv["general.basename"]
            // GGUF 自己知道角色：架构后缀 -mtp、general.type = adapter
            if let arch = id.architecture?.lowercased(), arch.hasSuffix("-mtp") || arch.hasSuffix("_mtp") {
                id.role = .mtp
            }
            if let t = head.kv["general.type"]?.lowercased(), t.contains("adapter") { id.role = .lora }
            if lower.contains("mmproj") { id.role = .projector }
            if lower.contains("mtp") { id.role = .mtp }
            id.quant = quantFromFilename(name) ?? head.kv["general.size_label"]
            if lower.hasPrefix("mtp") || lower.hasPrefix("mmproj") {
                // 部件文件的 general.name 只是母模型名，补上父目录以区分是哪一套权重里的
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                id.family = (id.family ?? quantStripped(parent))
            }
            if id.family == nil { id.family = quantStripped(name) }
        } else if lower.hasSuffix(".safetensors"), let md = safetensorsMeta(path) {
            id.format = "safetensors"
            id.family = md["modelspec.architecture"] ?? md["ss_base_model_version"] ?? md["format"]
            id.quant = quantFromFilename(name) ?? md["quantization"]
        } else {
            id.format = "未知"
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let isPart = lower.hasPrefix("mtp") || lower.hasPrefix("mmproj")
            id.family = isPart ? pickFamily(dirName: parent, headerName: nil,
                                            parentName: ((path as NSString).deletingLastPathComponent as NSString)
                                                .deletingLastPathComponent) : quantStripped(name)
            id.quant = quantFromFilename(name)
        }
        return id
    }

    // ---------- 目录 ----------
    static func identifyDirectory(_ path: String) -> ModelIdentity? {
        let fm = FileManager.default
        let dirName = (path as NSString).lastPathComponent
        var id = ModelIdentity()
        let lowerDir = dirName.lowercased()

        // 目录级角色：ComfyUI 的落盘结构
        if let r = roleFromTable(lowerDir) { id.role = r }
        if lowerDir.contains("lora") { id.role = .lora }
        if lowerDir == "vae" { id.role = .vae }
        if lowerDir.contains("text_encoder") || lowerDir.contains("text-encoder") { id.role = .textEncoder }
        if lowerDir.contains("mmproj") { id.role = .projector }

        // config.json：架构 / 量化（MLX 与 HF 通用）
        let cfgPath = path + "/config.json"
        var cfg: [String: Any]?
        if let d = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            cfg = obj
            if let archs = obj["architectures"] as? [String], let a = archs.first {
                id.architecture = a
            }
            if let mt = obj["model_type"] as? String {
                id.architecture = id.architecture ?? mt
            }
            // 家族名要给人看：优先 config 里的来源名，其次目录名，**不要**用架构类名
            // （`Qwen3_5ForConditionalGeneration` 这种没人认得出是哪个模型）
            if let src = obj["_name_or_path"] as? String, !src.isEmpty {
                id.family = (src as NSString).lastPathComponent
            }
            if let q = obj["quantization"] as? [String: Any] {
                var parts: [String] = []
                if let bits = q["bits"] as? Int { parts.append("\(bits)bit") }
                if let gs = q["group_size"] as? Int, gs > 0 { parts.append("gs\(gs)") }
                if let mode = q["mode"] as? String, mode != "affine" { parts.append(mode) }
                if !parts.isEmpty { id.quant = parts.joined(separator: " ") }
                id.format = "mlx"
            }
            if obj["adapter_config"] != nil || obj["peft_type"] != nil { id.role = .lora }
        }

        // 目录名兜底：`xxx-4bit` / `xxx-IQ3_S`
        if id.quant == nil { id.quant = quantFromFilename(dirName) }
        if id.family == nil {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            id.family = pickFamily(dirName: dirName, headerName: nil, parentName: parent)
        }
        if id.format == nil { id.format = "safetensors" }

        if cfg != nil { id.hasModelEvidence = true }

        // 权重文件：只数直接子层（最多两层，避免把整个快照树走一遍）
        var total: Int64 = 0
        var count = 0
        var largestInode: (size: Int64, key: String)? = nil
        var ggufRoles: [ModelRole] = []
        var biggestGGUF: (name: String, size: Int64, head: GGUFHead.Info)?
        let items = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for it in items.sorted() {
            let lower = it.lowercased()
            guard weightExts.contains(where: { lower.hasSuffix($0) }) else { continue }
            let full = path + "/" + it
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            total += size
            count += 1
            if lower.hasSuffix(".safetensors") || lower.hasSuffix(".ckpt") { id.hasModelEvidence = true }
            if let key = Self.inodeKey(full) {
                if largestInode == nil || size > largestInode!.size { largestInode = (size, key) }
            }
            if lower.hasSuffix(".gguf") { id.hasModelEvidence = true }
            if lower.hasSuffix(".gguf"), let head = GGUFHead.read(path: full) {
                let arch = head.kv["general.architecture"]?.lowercased() ?? ""
                if arch.hasSuffix("-mtp") || arch.hasSuffix("_mtp") || lower.contains("mtp") {
                    ggufRoles.append(.mtp)
                } else if lower.contains("mmproj") {
                    ggufRoles.append(.projector)
                } else {
                    ggufRoles.append(.main)
                }
                if id.quant == nil { id.quant = quantFromFilename(it) }
                // 记下最大的那个 gguf：没有 config.json 时它就是这目录的主权重
                if biggestGGUF == nil || size > biggestGGUF!.size {
                    biggestGGUF = (it, size, head)
                }
            }
        }
        // 没有任何 config.json 的纯 gguf 目录（例如 llama.cpp 的目录式权重）：
        // 以最大的 gguf 的头为准 —— 否则只能拿目录名当家族名，信息量差一截
        if cfg == nil, let big = biggestGGUF {
            id.format = "gguf"
            if let arch = big.head.kv["general.architecture"] { id.architecture = arch }
            if let q = quantFromFilename(big.name) { id.quant = q }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            id.family = pickFamily(dirName: dirName, headerName: big.head.kv["general.name"],
                                   parentName: parent)
        } else if count > 0 && id.format == nil {
            id.format = "safetensors"
        }
        // 只有草稿/投影、没有主权重：如果有子目录，说明这层是「一个集合」而不是一个模型 ⇒
        // 不当作模型返回（交给扫描器往深处走），否则界面会出现「草稿头集合」这种伪模型。
        if !ggufRoles.isEmpty, !ggufRoles.contains(.main) {
            let hasSubdir = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).contains { it in
                var d: ObjCBool = false
                return !it.hasPrefix(".") && fm.fileExists(atPath: path + "/" + it, isDirectory: &d) && d.boolValue
            }
            if hasSubdir { return nil }
            id.role = ggufRoles.contains(.mtp) ? .mtp : .projector
        }
        id.bytes = total
        id.files = count
        id.inodeKey = largestInode?.key
        if let fam = id.family, let q = id.quant, fam.lowercased() == q.lowercased() {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            id.family = pickFamily(dirName: parent, headerName: id.architecture, parentName: nil)
        }
        if count == 0 && cfg == nil { return nil }
        return id
    }

    // ---------- 小工具 ----------
    /// 会「像容器」的目录名：这时候目录名没有信息量，用文件头里的名字
    private static let containerishNames: Set<String> = [
        "gguf", "model", "models", "weights", "snapshots", "checkpoint", "checkpoints",
        "unet", "loras", "lora", "vae", "text_encoder", "text_encoders", "transformer",
        "diffusion_models", "pytorch_model", "controlnet", "ipadapter", "instantid",
    ]

    /// 家族名：目录名（去掉量化尾巴）通常最接近用户在 Finder 里看到的名字；
    /// 目录名是容器名（gguf / model / snapshots …）时才退回文件头里的名字。
    static func pickFamily(dirName: String, headerName: String?, parentName: String? = nil) -> String {
        let stripped = quantStripped(dirName)
        let key = stripped.lowercased()
        let looksContainer = containerishNames.contains(key)
            || key.hasPrefix("gguf-") || key.hasPrefix("snapshots")
            || key.range(of: "^[0-9a-f]{16,}$", options: .regularExpression) != nil
        if looksContainer {
            if let h = headerName, !h.isEmpty { return h }
            // `Qwen-Image-2.1/transformer`、`…/text_encoder`、`…/vae`：家族名是上一层那个目录
            if let p = parentName, !p.isEmpty { return quantStripped(p) }
        }
        return stripped.isEmpty ? (headerName ?? dirName) : stripped
    }
    /// 文件/目录的 `dev:ino`（硬链接共享 inode）
    static func inodeKey(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let dev = a[.systemNumber] as? NSNumber,
              let ino = a[.systemFileNumber] as? NSNumber else { return nil }
        return "\(dev.uint64Value):\(ino.uint64Value)"
    }

    /// 外部签名表里的角色词（`roles`）→ ModelRole；认不出的返回 nil 交给内置规则
    private static func roleFromTable(_ text: String) -> ModelRole? {
        let roles = AdapterTable.shared.roles
        guard !roles.isEmpty else { return nil }
        // 长的词优先，避免 "adapter" 抢走 "vae_adapter" 这类更具体的情况
        for key in roles.keys.sorted(by: { $0.count > $1.count }) where text.contains(key) {
            switch (roles[key] ?? "").lowercased() {
            case "main", "主权重": return .main
            case "mtp", "草稿头": return .mtp
            case "projector", "mmproj", "视觉投影": return .projector
            case "lora", "LoRA": return .lora
            case "vae", "VAE": return .vae
            case "textencoder", "text_encoder", "文本编码器": return .textEncoder
            case "other", "其它": return .other
            default: continue
            }
        }
        return nil
    }

    static func roleFromName(_ lowerName: String, parent: String) -> ModelRole {
        // 外部表优先：新部件类型（比如某引擎的 "vision_tower"）加一行 JSON 就认
        if let r = roleFromTable(lowerName) { return r }
        if let r = roleFromTable(parent) { return r }
        if lowerName.contains("mmproj") { return .projector }
        if lowerName.contains("mtp") { return .mtp }
        if lowerName.contains("lora") || lowerName.contains("adapter") { return .lora }
        if parent == "vae" || lowerName.contains("vae") { return .vae }
        if parent.contains("text_encoder") || lowerName.contains("text_encoder") { return .textEncoder }
        return .main
    }

    static func quantFromFilename(_ name: String) -> String? {
        let upper = name.uppercased()
        for q in quantWords where upper.contains(q) { return q }
        // 4bit / 8bit / 6bit 这类 MLX 命名
        if let r = upper.range(of: "[0-9]+BIT", options: .regularExpression) {
            return String(upper[r]).lowercased()
        }
        return nil
    }

    /// 去掉量化尾巴，剩下的当展示名
    static func quantStripped(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension
        let upper = s.uppercased()
        for q in quantWords where upper.hasSuffix("-" + q) || upper.hasSuffix("_" + q) || upper.hasSuffix("." + q) {
            s = String(s.dropLast(q.count + 1))
            break
        }
        if let r = s.range(of: "[-_.][0-9]+bit$", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        return s
    }

    /// 只读 safetensors 的 JSON 头（8 字节 LE 长度 + JSON）
    static func safetensorsMeta(_ path: String) -> [String: String]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let lenData = try? fh.read(upToCount: 8), lenData.count == 8 else { return nil }
        var n: UInt64 = 0
        for i in (0..<8).reversed() { n = n << 8 | UInt64(lenData[lenData.startIndex + i]) }
        guard n > 0, n < 16 << 20 else { return nil }
        guard let json = try? fh.read(upToCount: Int(n)), json.count == Int(n),
              let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let md = obj["__metadata__"] as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in md { if let s = v as? String { out[k] = s } }
        return out
    }
}
