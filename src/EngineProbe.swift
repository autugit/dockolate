// ============================================================
// 本机 AI 引擎探测（通用版）
// ============================================================
//
// 目标：别人电脑上装了什么本地模型 / 生图引擎，这里都能认出来并说清「此刻在跑什么」，
// 不依赖任何一家的私有网关（早期实现读的是本机 oMLX 网关 /v1/models 里的 local.resident，
// 那只在一台机器上成立）。
//
// 两路交叉，缺一不可：
//   ① 端口探测：内置已知引擎端口表，逐个试各家「当前加载了什么」的 API；
//   ② 进程扫描：libproc 取物理内存 + LISTEN 端口 + 计算活动，兜住没有服务端口的应用内模型。
//
// 各引擎取「当前加载」的接口（按顺序尝试，第一个能解析出结构的算数）：
//   Ollama        GET /api/ps            → models[].name（配 /api/tags 求差集 = 已下载未加载）
//   LM Studio     GET /api/v0/models     → data[] 的 state == "loaded"
//   A1111 / DT    GET /sdapi/v1/options  → sd_model_checkpoint
//   ComfyUI       GET /queue → /history?max_items=1 的 ckpt_name / unet_name
//   OpenAI 兼容   GET /v1/models         → data[].id（llama.cpp / vLLM / oMLX / MLX / TGWebUI / KoboldCpp）
//
// 拿不到模型名就只显示引擎名 + 端口，不编。

import Cocoa

// ============================================================
// MARK: - 数据模型
// ============================================================

enum ModelState {
    case running, idle, failed, unloaded, loading, uncertain, unregistered

    var text: String {
        switch self {
        case .running:   return "正在运行"
        case .idle:      return "挂载待机"
        case .failed:    return "出现故障"
        case .unloaded:  return "未加载"
        case .loading:   return "加载中"
        case .uncertain: return "待确认"
        case .unregistered: return "在盘未登记"
        }
    }

    var color: NSColor {
        switch self {
        case .running:   return NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)  // 绿
        case .idle:      return NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.95, alpha: 1)  // 蓝
        case .failed:    return NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.28, alpha: 1)  // 红
        case .unloaded:  return .tertiaryLabelColor
        case .loading:   return NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.25, alpha: 1)  // 琥珀
        case .uncertain: return NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.88, alpha: 1)  // 紫
        case .unregistered: return .secondaryLabelColor
        }
    }
}

struct ModelRow {
    var name: String
    var memGB: Double
    var state: ModelState
    var note: String
    var pid: pid_t? = nil       // 仅内部用：判定「一个进程托管多个模型 ⇒ 内存是合计」
    var shared: Bool = false
}

struct ModelSnapshot {
    var rows: [ModelRow] = []
    var unloaded: [String] = []      // 已下载但没加载（只有 Ollama / LM Studio 提供这个信息）
    var enginesFound = 0             // 探测到几个活着的引擎端口
    var scannedPorts: [Int] = []
    /// 引擎自己声明的权重目录（argv 里的 --model-dir / --model-path / --model 的目录部分）。
    /// 清单层拿它当扫描根 —— 「引擎从哪儿加载，就去哪儿清点」，比猜用户目录可靠。
    var modelDirs: [String] = []
}

// ============================================================
// MARK: - 本地 HTTP（原始 socket，不走系统代理）
// ============================================================
//
// 不能用 URLSession/URLSessionTask 直接打 127.0.0.1：它们会读系统代理设置，
// 代理一开就连不上本地服务（实测过 python urllib 与 URLSession 都有这个问题）。

enum LocalHTTP {
    static func connectable(port: Int, timeoutMs: Int32 = 300) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: timeoutMs * 1000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// 极简 HTTP/1.0 GET，返回 body（去掉响应头）；连接失败返回 nil
    static func body(port: Int, path: String, timeoutMs: Int32 = 600, maxBytes: Int = 512 * 1024,
                     headers: [String: String] = [:]) -> String? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: timeoutMs * 1000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let cr = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(s, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard cr == 0 else { return nil }
        var head = "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nAccept: application/json\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        _ = head.withCString { write(s, $0, strlen($0)) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while data.count < maxBytes {
            let n = read(s, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let r = text.range(of: "\r\n\r\n") else { return nil }
        return String(text[r.upperBound...])
    }

    static func json(port: Int, path: String, timeoutMs: Int32 = 600,
                     headers: [String: String] = [:]) -> Any? {
        guard let b = body(port: port, path: path, timeoutMs: timeoutMs, headers: headers),
              let d = b.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}

// ============================================================
// MARK: - 引擎探测
// ============================================================

/// 一个探测到活着的引擎
struct EngineHit {
    var kind: String
    var port: Int
    var loaded: [String] = []       // 此刻加载 / 正在跑的模型
    var unloaded: [String] = []     // 已下载但没加载（只有 Ollama / LM Studio 给得出）
    /// 每个已加载模型的常驻字节（服务自己报的，比进程 RSS 更贴「这个模型占多少」）。
    /// 一个进程能同时驻留多个模型，进程内存在那种情况下是合计，分不出单个。
    var resident: [String: Int64] = [:]
    /// 正在加载 / 加载失败的模型（有的服务把加载中的权重也列出来，状态单独给）
    var loading: [String] = []
    var failed: [String] = []
    /// 引擎自报、但我们映射不了的状态（原样显示，见判据 R3）
    var reported: [String: String] = [:]
    /// 诊断用：选中的适配器与信息量评分（进发现报告）
    var adapter: String = ""
    var score: Int = 0
    /// 证据不足 / 载荷形状不认识 ⇒ 界面显示「待确认」，不硬下结论（判据 R2 / R6）
    var uncertain: Bool = false
    var evidenceNote: String = ""
}

/// 扫描到的模型服务进程
struct ModelProc {
    var pid: pid_t
    var ppid: pid_t = 0        // 进程树归并用：Splash 这类「父进程监听端口、子进程跑推理」的引擎，
                               // 只按监听端口取 holder 会拿到几十 MB 的空壳，真实权重在子进程里
    var kind: String
    var display: String
    var memBytes: UInt64
    var cpuNs: UInt64
    var ports: [Int]
    var modelDirs: [String] = []   // argv 里声明的权重目录（清单层扫描根）
}

final class EngineWatcher {
    /// 端口 → 引擎名的**兜底表**：只在进程认不出来（classify 失败）时用来给个名字。
    /// 只收各家**官方默认端口**；自定义端口不用管 —— 进程实际监听的端口本来就会被扫到并探测。
    /// ⚠️ 不要把反向代理 / 网关端口登记成引擎：同一个真实模型会被列两遍。
    static let knownEngines: [Int: String] = [
        // 对话模型
        11434: "Ollama",
        1234:  "LM Studio",
        1337:  "Jan",
        4891:  "GPT4All",
        3000:  "OpenLLM",
        4000:  "LiteLLM",
        5000:  "text-generation-webui",
        5001:  "KoboldCpp",
        8000:  "本地推理服务",          // vLLM 的默认端口，也是多数 OpenAI 兼容服务的默认
        8080:  "llama.cpp",             // llama-server 的默认端口
        9997:  "Xinference",
        30000: "SGLang",
        // 图像 / 视频
        7801:  "SwarmUI",
        7860:  "A1111 / SD.Next / Draw Things",
        7861:  "A1111",
        7865:  "Fooocus",
        8188:  "ComfyUI",
        8189:  "ComfyUI",
        9090:  "InvokeAI",
    ]

    private let activeWindow: TimeInterval = 12        // 最近多少秒算过东西 ⇒ 正在运行
    private let activeThreshold: TimeInterval = 0.03   // 2 秒窗口内 30 ms 计算量即算「在算」

    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevGPU: [pid_t: Int] = [:]
    private var prevAt = Date()
    private var lastActive: [pid_t: Date] = [:]

    /// 额外探测端口（用户自定义引擎，来自 engines.json 或 --ports=）
    var extraPorts: [Int] = []
    /// 自检用：只探 extraPorts（回归测试要排除本机真在跑的引擎）
    var portsOnly = false
    /// 外部签名表（内置 resources/adapters.json + 用户覆盖）。纯数据层，新引擎不必等发版。
    let adapters = AdapterTable.shared
    /// 每个端口的 API key（有些服务——比如 oMLX——无 key 一律 401，拿不到模型名）
    var apiKeys: [Int: String] = [:]
    private var configLoaded = false

    /// 读 ~/Library/Application Support/Dockolate/engines.json：
    /// { "extraPorts": [9000], "apiKeys": { "9000": "sk-..." } }
    private func loadConfigIfNeeded() {
        guard !configLoaded else { return }
        configLoaded = true
        let path = NSHomeDirectory() + "/Library/Application Support/Dockolate/engines.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if let ports = obj["extraPorts"] as? [Int] { extraPorts.append(contentsOf: ports) }
        if let keys = obj["apiKeys"] as? [String: String] {
            for (k, v) in keys { if let p = Int(k), !v.isEmpty { apiKeys[p] = v } }
        }
    }

    /// 鉴权头：配置里的 key > 环境变量 DOCKOLATE_KEY_<端口> > DOCKOLATE_KEY
    private func authHeaders(_ port: Int) -> [String: String] {
        if let k = apiKeys[port], !k.isEmpty { return ["Authorization": "Bearer \(k)"] }
        let env = ProcessInfo.processInfo.environment
        if let k = env["DOCKOLATE_KEY_\(port)"], !k.isEmpty { return ["Authorization": "Bearer \(k)"] }
        if let k = env["DOCKOLATE_KEY"], !k.isEmpty { return ["Authorization": "Bearer \(k)"] }
        return [:]
    }

    // ---------- 一、进程识别 ----------
    // 进程名 / 路径 / argv 里的特征词 → 显示名。**顺序即优先级**：具体的写在前面，
    // 泛化的（mlx / whisper）放后面兜底，否则 "reforge" 会被 "forge" 吃掉。
    private let kindHints: [(String, String)] = [
        // 本机 MLX 系引擎
        ("omlx", "oMLX"),
        ("splash", "Splash"),                  // Splash 1.4：engine/splash serve-native，权重跑在这层
        ("mtplx", "MTPLX"),
        ("flash-next", "Flash-Next"), ("flashnext", "Flash-Next"),
        ("swift-qwen", "Swift-Qwen"), ("swift_qwen", "Swift-Qwen"),
        ("dflash", "DFlash"),                  // 草稿模型偶尔单独起服务
        ("mlx-serve", "mlx-serve"), ("mlx_serve", "mlx-serve"),   // 必须在泛化的 "mlx" 之前
        ("mlx_lm.server", "MLX"), ("mlx_vlm.server", "MLX"), ("mlx-lm", "MLX"), ("mlx_vlm", "MLX"),
        ("mlx", "MLX"),

        // llama.cpp 家族
        ("llama-server", "llama.cpp"), ("llama_server", "llama.cpp"),
        ("llama.cpp", "llama.cpp"), ("llama-cpp", "llama.cpp"), ("llamacpp", "llama.cpp"),
        ("llamafile", "llamafile"),

        // 通用 LLM 服务
        ("ollama", "Ollama"),
        ("lmstudio", "LM Studio"), ("lm studio", "LM Studio"),
        ("vllm", "vLLM"),
        ("sglang", "SGLang"),
        ("tensorrt", "TensorRT-LLM"), ("trtllm", "TensorRT-LLM"),
        ("text-generation-inference", "TGI"),
        ("text-generation-webui", "text-generation-webui"),
        ("kobold", "KoboldCpp"),
        ("localai", "LocalAI"),
        ("xinference", "Xinference"),
        ("fastchat", "FastChat"),
        ("openllm", "OpenLLM"),
        ("litellm", "LiteLLM"),
        ("tabby", "TabbyAPI"),
        ("ktransformers", "KTransformers"),
        ("mlc_llm", "MLC LLM"), ("mlc-llm", "MLC LLM"),
        ("ramalama", "RamaLama"),
        ("petals", "Petals"),
        ("gpt4all", "GPT4All"),
        ("jan.app", "Jan"),
        ("model-runner", "Docker Model Runner"),
        ("webui.py", "A1111"),                 // 必须在 text-generation-webui 之后

        // 图像 / 视频
        ("comfyui", "ComfyUI"), ("comfy", "ComfyUI"),
        ("swarmui", "SwarmUI"),
        ("fooocus", "Fooocus"),
        ("invokeai", "InvokeAI"), ("invoke-ai", "InvokeAI"),
        ("sd.next", "SD.Next"), ("sdnext", "SD.Next"),
        ("stable-diffusion.cpp", "sd.cpp"), ("sd-server", "sd.cpp"), ("sd-cli", "sd.cpp"),
        ("stable-diffusion-webui", "A1111"), ("a1111", "A1111"),
        ("reforge", "reForge"), ("forge", "Forge"),   // reforge 必须在 forge 之前
        ("draw things", "Draw Things"), ("drawthings", "Draw Things"), ("draw-things", "Draw Things"),
        ("diffusionbee", "DiffusionBee"),
        ("amuse", "Amuse"),
        ("mflux", "mflux"),
        ("diffusers", "Diffusers"),
        ("qwen-image", "Qwen-Image"), ("qwen_image", "Qwen-Image"),
        ("flux", "Flux"),
        ("wan2", "Wan"), ("wan-2", "Wan"),
        ("minimax", "MiniMax"),
        ("hunyuan", "HunyuanVideo"),
        ("ltx-video", "LTX-Video"), ("ltx_video", "LTX-Video"),
        ("cogvideo", "CogVideo"),

        // 语音
        ("whisper", "Whisper"),                // whisper.cpp / faster-whisper 都归这里
        ("kokoro", "Kokoro TTS"),
        ("coqui", "Coqui TTS"),
        ("chattts", "ChatTTS"),
        ("piper", "Piper TTS"),
        ("xtts", "XTTS"),
    ]
    // ⚠️ 外部签名表（resources/adapters.json + 用户覆盖）里的 processHints **优先于**上表，
    //    所以引擎改名/新增不必等发版；上表只是内置默认值。
    // 快速筛选用：只为「值不值得深扫这个进程」把关，所以只放足够具体的词。
    // 放泛词（swift / exo / wan）会让每 2 秒一次的扫描多跑几十个无关进程的 argv+fd 解析。
    private let quickHints = ["omlx", "splash", "llama", "mlx", "ollama", "lmstudio", "lm studio",
                              "vllm", "sglang", "kobold", "comfy", "draw things", "drawthings",
                              "mflux", "fooocus", "invokeai", "stable-diffusion", "sd-server",
                              "sdnext", "sd.next", "diffusers", "qwen-image", "qwen_image",
                              "localai", "xinference", "fastchat", "openllm", "tabby", "llamafile",
                              "ktransformers", "mlc_llm", "mlc-llm", "ramalama", "petals", "gpt4all",
                              "jan.app", "text-generation", "tensorrt", "trtllm", "model-runner",
                              "swarmui", "diffusionbee", "amuse", "wan2", "wan-2", "minimax",
                              "hunyuan", "ltx-video", "ltx_video", "cogvideo",
                              "whisper", "kokoro", "coqui", "chattts", "piper", "xtts",
                              "mtplx", "swift-qwen", "swift_qwen", "flash-next", "flashnext", "dflash"]
    private let interpreters = ["python", "python3", "node", "ruby", "java", "uv", "uvicorn"]

    private func classify(name: String, path: String, argv: [String]) -> String? {
        let head = argv.first ?? ""
        let hay = (name + " " + path + " " + head).lowercased()
        for (k, v) in adapters.processHints where hay.contains(k) { return v }   // 外部表优先（可覆盖内置）
        for (k, v) in kindHints where hay.contains(k) { return v }
        return nil
    }

    /// argv 里声明的权重目录：`--model-dir X` / `--model-path X` / `--model X`
    /// 只收「看起来是目录」的（存在且是目录，或是绝对路径）—— 避免把仓库 id 当路径。
    private func modelDirsFromArgv(_ argv: [String]) -> [String] {
        let flags = ["--model-dir", "--model-path", "--model", "-m", "--models", "--model_dir"]
        var out: [String] = []
        func consider(_ v: String) {
            guard !v.hasPrefix("-") else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: v, isDirectory: &isDir), isDir.boolValue {
                out.append((v as NSString).standardizingPath)
            } else if v.hasPrefix("/") {
                // 可能是目录本身或目录下的某个文件：取父目录再确认一次
                let parent = (v as NSString).deletingLastPathComponent
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: parent, isDirectory: &d), d.boolValue {
                    out.append(parent)
                }
            }
        }
        for (i, a) in argv.enumerated() {
            if flags.contains(a), i + 1 < argv.count { consider(argv[i + 1]) }
            for f in flags where a.hasPrefix(f + "=") {
                consider(String(a.dropFirst(f.count + 1)))
            }
        }
        return out
    }

    /// 模型名：优先 argv 里的 --model / -m 等；不够再退回引擎名
    private func modelDisplay(argv: [String], kind: String) -> String {
        let flags = ["--model", "-m", "--model-path", "--model-dir", "--hf-repo", "--model-id", "--repo-id"]
        for (i, a) in argv.enumerated() {
            if flags.contains(a), i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
                let base = (argv[i + 1] as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
            for f in flags where a.hasPrefix(f + "=") {
                let base = (String(a.dropFirst(f.count + 1)) as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
        }
        for a in argv where a.hasSuffix(".gguf") {
            return ((a as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return kind
    }

    // ---------- 二、进程数据 ----------
    private func argvOf(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        var idx = 4
        while idx < size && buf[idx] != 0 { idx += 1 }   // 跳过可执行路径
        while idx < size && buf[idx] == 0 { idx += 1 }   // 跳过填充
        var out: [String] = []
        var n: Int32 = 0
        while n < argc && idx < size {
            var end = idx
            while end < size && buf[end] != 0 { end += 1 }
            out.append(String(decoding: buf[idx..<end], as: UTF8.self))
            n += 1
            idx = end + 1
        }
        return out
    }

    private func rusageOf(_ pid: pid_t) -> (mem: UInt64, cpuNs: UInt64)? {
        var info = rusage_info_current()
        let kr = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rp)
            }
        }
        guard kr == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_user_time + info.ri_system_time)
    }

    /// 父进程 pid —— 进程树归并用。
    /// 有的引擎是「小父进程只做 HTTP、子进程持有权重并跑推理」的两层结构（Splash 1.4 就是这样），
    /// 只认监听端口的那个 pid 会得到一个空壳的内存数字。
    private func ppidOf(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        return r > 0 ? pid_t(info.pbi_ppid) : 0
    }

    /// 该进程处于 LISTEN 状态的 TCP 端口。
    /// 坑：macOS 27 内核的 struct socket_info 比 SDK 头文件大 24 字节（792 vs 768），
    /// 直接 cast 成 Swift 结构体会整体错位（读出的 soi_kind 是垃圾值）；
    /// 这里按「返回字节数 − 结构体大小」做偏移补偿，并用 soi_kind / soi_family 双重校验。
    private func listeningPorts(_ pid: pid_t) -> [Int] {
        let maxFD = 2048
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: maxFD)
        let sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                              Int32(maxFD * MemoryLayout<proc_fdinfo>.stride))
        guard sz > 0 else { return [] }
        let n = Int(sz) / MemoryLayout<proc_fdinfo>.stride
        var ports: [Int] = []
        for i in 0..<n {
            guard fds[i].proc_fdtype == 2 else { continue }   // PROX_FDTYPE_SOCKET
            var buf = [UInt8](repeating: 0, count: 2048)
            let r = buf.withUnsafeMutableBytes { raw -> Int32 in
                proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO,
                               raw.baseAddress, Int32(raw.count))
            }
            guard r > 0 else { continue }
            let shift = Int(r) - MemoryLayout<socket_info>.stride
            guard shift >= 0, shift <= 64 else { continue }

            func i32(_ off: Int) -> Int32 {
                let o = off + shift
                guard o >= 0, o + 4 <= buf.count else { return 0 }
                var v: Int32 = 0
                withUnsafeMutableBytes(of: &v) { dst in
                    buf.withUnsafeBytes { src in
                        dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[o..<o + 4]))
                    }
                }
                return v
            }

            guard i32(232) == 2,                                   // soi_kind == SOCKINFO_TCP
                  i32(160) == AF_INET || i32(160) == AF_INET6 else { continue }   // soi_family
            guard i32(320) == 1 else { continue }                  // pri_tcp.tcpsi_state == TCPS_LISTEN
            let raw = UInt16(truncatingIfNeeded: i32(244))         // pri_in.insi_lport（网络字节序）
            ports.append(Int(raw.bigEndian))
        }
        return ports
    }

    // ---------- 三、端口探测 ----------
    /// 深度找工作流节点里的权重名：优先 ckpt / unet，其次通用字段（LoRA、VAE 不当主模型）
    private func firstWeightName(_ obj: Any) -> String? {
        var ckpt: String?
        var unet: String?
        var generic: String?
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let inputs = d["inputs"] as? [String: Any] {
                    if ckpt == nil, let s = inputs["ckpt_name"] as? String, !s.isEmpty { ckpt = s }
                    if unet == nil, let s = inputs["unet_name"] as? String, !s.isEmpty { unet = s }
                    if generic == nil {
                        for k in ["diffusion_model", "model_name", "gguf_name"] {
                            if let s = inputs[k] as? String, !s.isEmpty { generic = s; break }
                        }
                    }
                }
                for sub in d.values { walk(sub) }
            } else if let a = v as? [Any] {
                for sub in a { walk(sub) }
            }
        }
        walk(obj)
        return ckpt ?? unet ?? generic
    }

    private func cleanWeightName(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let exts = [".safetensors", ".ckpt", ".pt", ".pth", ".gguf", ".bin"]
        let lower = trimmed.lowercased()
        // 绝对路径或带权重扩展名 → 取文件名；仓库式 id（org/model、子目录里的模型）保留整段，
        // 否则会把「a/b」显示成「b」，看着像另一个模型（同一型号的不同量化版本尤其容易撞名）
        var base = trimmed.hasPrefix("/") || exts.contains(where: { lower.hasSuffix($0) })
            ? (trimmed as NSString).lastPathComponent
            : trimmed
        // A1111 会带 " [hash]" 尾巴
        if let r = base.range(of: " [") { base = String(base[..<r.lowerBound]) }
        for ext in exts where base.lowercased().hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
        // Ollama 兼容层的默认标签 ":latest" 是噪声；真标签（":8b" 之类）保留
        if base.hasSuffix(":latest") { base = String(base.dropLast(":latest".count)) }
        return base
    }

    // ---------- 三、端口探测：先收全部候选，再按「载荷说得多清楚」挑一个 ----------
    // v1.3（R1）：判据是信息量，不是谁先写完。半套 Ollama 兼容层的 `/api/ps` 只回空表，
    // 却曾因为分支写在前面，把真实状态（/v1/models 里的 ready / loading）整段盖掉。
    struct ProbeCandidate {
        var adapter: String                  // 适配器名（诊断与报告用，不参与判定）
        var score: Int = 0                   // 信息量评分
        var loaded: [String] = []
        var unloaded: [String] = []
        var loading: [String] = []
        var failed: [String] = []
        var reported: [String: String] = [:]  // 引擎自报、但我们映射不了的原始状态（原样透传）
        var resident: [String: Int64] = [:]
    }

    /// 该条目属于哪一档。映射不了返回 nil —— 调用方原样透传，**绝不并进「未加载」**。
    private enum ModelBucket { case resident, loading, failed, absent }
    private func bucketOf(_ raw: String) -> ModelBucket? {
        let key = raw.lowercased()
        if let b = adapters.states[key] {
            switch b {
            case .resident: return .resident
            case .loading:  return .loading
            case .failed:   return .failed
            case .absent:   return .absent
            }
        }
        switch key {
        case "ready", "loaded", "running", "serving", "active": return .resident
        case "loading", "unloading", "warming", "starting": return .loading
        case "error", "failed", "crashed": return .failed
        case "unloaded", "idle", "stopped", "absent", "not_loaded", "not-loaded": return .absent
        default: return nil
        }
    }

    /// 信息量评分：只用来排序候选，不参与「加载 / 未加载」的判定。
    private func infoScore(stateful: Bool, resident: Bool, diskOrQuant: Bool,
                           count: Int, selfName: Bool) -> Int {
        (stateful ? 3 : 0) + (resident ? 2 : 0) + (diskOrQuant ? 2 : 0)
            + (count > 0 ? 1 : 0) + (selfName ? 1 : 0)
    }

    /// 把每个接口的响应都解析成候选（不做取舍）。**空数组一律 0 分**：
    /// 它只能证明「这个接口此刻没东西」，不能证明「没有模型」（R2 的基础）。
    func collectCandidates(port: Int, auth: [String: String]) -> [ProbeCandidate] {
        var out: [ProbeCandidate] = []

        // ① /v1/models —— OpenAI 兼容；现代引擎还会逐条带状态与常驻字节
        if let m = LocalHTTP.json(port: port, path: "/v1/models", headers: auth) as? [String: Any],
           let data = m["data"] as? [[String: Any]], !data.isEmpty {
            var c = ProbeCandidate(adapter: "v1-models")
            var stateful = false, hasResident = false, hasDiskOrQuant = false, hasSelfName = false
            var names: [String] = []
            for e in data {
                guard let id = e["id"] as? String else { continue }
                let name = cleanWeightName(id)
                names.append(name)
                let rawState = e["state"] as? String
                let flag = e["loaded"] as? Bool
                let resident = (e["bytes_resident"] as? NSNumber)?.int64Value
                if rawState != nil || flag != nil { stateful = true }
                if resident != nil { hasResident = true }
                if (e["bytes_on_disk"] as? NSNumber) != nil || e["quantization"] != nil { hasDiskOrQuant = true }
                if (e["owned_by"] as? String) != nil { hasSelfName = true }

                if let raw = rawState {
                    switch bucketOf(raw) {
                    case .resident: c.loaded.append(name)
                                    if let r = resident, r > 0 { c.resident[name] = r }
                    case .loading:  c.loading.append(name)
                    case .failed:   c.failed.append(name)
                    case .absent:   c.unloaded.append(name)
                    case nil:       c.reported[name] = raw      // 认不出的状态：原样透传（R3）
                    }
                } else if (flag ?? ((resident ?? 0) > 0)) {
                    c.loaded.append(name)
                    if let r = resident, r > 0 { c.resident[name] = r }
                } else {
                    c.unloaded.append(name)
                }
            }
            if stateful { c.adapter = "v1-models+state" }
            // 完全没有状态字段的 OpenAI 兼容服务（llama.cpp / vLLM …）：列出来就是加载着，
            // 单模型服务本来如此 —— 与 v1.2 的行为保持一致。
            if !stateful && !hasResident {
                c.loaded = names
                c.unloaded = []; c.loading = []; c.failed = []; c.reported = [:]
            }
            c.score = infoScore(stateful: stateful, resident: hasResident, diskOrQuant: hasDiskOrQuant,
                                count: data.count, selfName: hasSelfName)
            out.append(c)
        }

        // ② Ollama /api/ps（在跑）+ /api/tags（已下载）
        if let ps = LocalHTTP.json(port: port, path: "/api/ps", headers: auth) as? [String: Any],
           let models = ps["models"] as? [[String: Any]] {
            var c = ProbeCandidate(adapter: "ollama")
            c.loaded = models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
                .map(cleanWeightName)
            if let tags = LocalHTTP.json(port: port, path: "/api/tags", headers: auth) as? [String: Any],
               let all = tags["models"] as? [[String: Any]] {
                let allNames = all.compactMap { $0["name"] as? String }.map(cleanWeightName)
                c.unloaded = allNames.filter { !c.loaded.contains($0) }
            }
            c.score = c.loaded.isEmpty ? 0
                : infoScore(stateful: false, resident: false, diskOrQuant: false,
                            count: c.loaded.count, selfName: !c.unloaded.isEmpty)
            out.append(c)
        }

        // ③ LM Studio /api/v0/models
        if let m = LocalHTTP.json(port: port, path: "/api/v0/models", headers: auth) as? [String: Any],
           let data = m["data"] as? [[String: Any]], !data.isEmpty {
            var c = ProbeCandidate(adapter: "lmstudio")
            var stateful = false
            for e in data {
                guard let id = e["id"] as? String else { continue }
                let name = cleanWeightName(id)
                let raw = (e["state"] as? String) ?? ""
                if !raw.isEmpty { stateful = true }
                if bucketOf(raw) == .resident { c.loaded.append(name) } else { c.unloaded.append(name) }
            }
            c.score = infoScore(stateful: stateful, resident: false, diskOrQuant: false,
                                count: data.count, selfName: false)
            out.append(c)
        }

        // ④ A1111 / Forge / Draw Things
        if let opt = LocalHTTP.json(port: port, path: "/sdapi/v1/options", headers: auth) as? [String: Any],
           let ckpt = opt["sd_model_checkpoint"] as? String, !ckpt.isEmpty {
            var c = ProbeCandidate(adapter: "sdapi")
            c.loaded = [cleanWeightName(ckpt)]
            c.score = infoScore(stateful: false, resident: false, diskOrQuant: true, count: 1, selfName: false)
            out.append(c)
        }

        // ⑤ ComfyUI：/queue 结构存在即认它，模型名从队列或最近历史里取
        if let q = LocalHTTP.json(port: port, path: "/queue", headers: auth) as? [String: Any],
           q["queue_running"] != nil || q["queue_pending"] != nil {
            var c = ProbeCandidate(adapter: "comfyui")
            var name = firstWeightName(q)
            if name == nil,
               let h = LocalHTTP.json(port: port, path: "/history?max_items=1", headers: auth) {
                name = firstWeightName(h)
            }
            if let n = name { c.loaded = [cleanWeightName(n)] }
            c.score = infoScore(stateful: false, resident: false, diskOrQuant: true,
                                count: name == nil ? 0 : 1, selfName: true)
            out.append(c)
        }

        return out
    }

    /// 认一个端口：收全部候选 → 按信息量取最高分（同分保持声明顺序）→ 无候选则返回 nil。
    func detectEngine(port: Int, hint: String) -> EngineHit? {
        let auth = authHeaders(port)
        let cands = collectCandidates(port: port, auth: auth)
        var best: ProbeCandidate?
        for c in cands where best == nil || c.score > best!.score { best = c }
        guard let pick = best else { return nil }

        // R2：任何一个「没在跑什么」的结论，都要两条**互相独立**的负面证据。
        // 实测：fd 权重句柄不可靠（按需加载、用完释放的引擎加载完一个 sizeof 都不留），
        // 所以否定判据只用两条协议级证据，不用 fd。
        var negatives: [String] = []
        if let v1 = cands.first(where: { $0.adapter.hasPrefix("v1-models") }) {
            if v1.loaded.isEmpty && v1.loading.isEmpty && v1.reported.isEmpty {
                negatives.append("/v1/models 无常驻条目")
            }
        } else {
            negatives.append("/v1/models 无结构")
        }
        if let oll = cands.first(where: { $0.adapter == "ollama" }) {
            if oll.loaded.isEmpty { negatives.append("/api/ps 为空") }
        } else if let lm = cands.first(where: { $0.adapter == "lmstudio" }) {
            if lm.loaded.isEmpty { negatives.append("/api/v0/models 无 loaded 条目") }
        } else {
            negatives.append("Ollama / LM Studio 接口均无应答")
        }

        let nothingRunning = pick.loaded.isEmpty && pick.loading.isEmpty
            && pick.failed.isEmpty && pick.reported.isEmpty
        // 证据不足时不下「没有加载模型」的结论，改成「待确认」并把看到的证据写出来。
        let uncertain = nothingRunning && negatives.count < 2

        var hit = EngineHit(kind: hint, port: port, loaded: pick.loaded, unloaded: pick.unloaded,
                            resident: pick.resident, loading: pick.loading, failed: pick.failed)
        hit.reported = pick.reported
        hit.adapter = pick.adapter
        hit.score = pick.score
        hit.uncertain = uncertain
        hit.evidenceNote = uncertain
            ? "证据不足，不下结论（\(negatives.isEmpty ? "无负面证据" : negatives.joined(separator: "；"))）"
            : ""
        return hit
    }

    // ---------- 四、一次完整采样 ----------
    func refresh() -> ModelSnapshot {
        loadConfigIfNeeded()
        let now = Date()
        var snap = ModelSnapshot()

        // 4.1 扫进程（谁真占着内存、谁在监听、谁在算）
        var procs: [ModelProc] = []
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(pids.count * MemoryLayout<pid_t>.stride))
        let count = max(0, Int(bytes) / MemoryLayout<pid_t>.stride)
        let selfPid = getpid()
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, pid != selfPid else { continue }
            var nameBuf = [CChar](repeating: 0, count: 1024)
            let nlen = proc_name(pid, &nameBuf, 1024)
            let pname = nlen > 0 ? String(cString: nameBuf) : ""
            var pathBuf = [CChar](repeating: 0, count: 4096)
            _ = proc_pidpath(pid, &pathBuf, 4096)
            let ppath = String(cString: pathBuf)

            let quick = (pname + " " + ppath).lowercased()
            let suspicious = quickHints.contains { quick.contains($0) }
                || adapters.processHints.contains { quick.contains($0.keyword) }
                || interpreters.contains { pname.lowercased().hasPrefix($0) }
            guard suspicious else { continue }

            let argv = argvOf(pid)
            let ports = listeningPorts(pid)
            let ppid = ppidOf(pid)
            var kind = classify(name: pname, path: ppath, argv: argv)
            if kind == nil, let p0 = ports.first, let hint = EngineWatcher.knownEngines[p0],
               interpreters.contains(where: { pname.lowercased().hasPrefix($0) }) {
                kind = hint
            }
            guard let kind = kind else { continue }
            guard let ru = rusageOf(pid) else { continue }
            // 有监听端口的服务不设内存门槛（权重可能 mmap 在别处，主进程本身可能只有几十 MB）；
            // 没有端口的（GUI 应用 / 库）要求真占着内存，避免把客户端壳子算进来
            if ports.isEmpty && ru.mem < 300 * 1024 * 1024 { continue }
            procs.append(ModelProc(pid: pid, ppid: ppid, kind: kind,
                                   display: modelDisplay(argv: argv, kind: kind),
                                   memBytes: ru.mem, cpuNs: ru.cpuNs,
                                   ports: ports,
                                   modelDirs: modelDirsFromArgv(argv)))
        }

        // 4.1b portsOnly（自检用）：把本机真在跑、但不在 extraPorts 里的引擎进程剔掉，
        // 否则它们会从「端口没覆盖到的进程」那条分支混进结果，污染回归断言。
        if portsOnly {
            procs.removeAll { p in
                !p.ports.isEmpty && p.ports.allSatisfy { !extraPorts.contains($0) }
            }
        }

        // 4.2 活动判定（CPU 或 GPU 时间在涨 ⇒ 正在算）
        let gpu = readGPUClientTimes()?.byPid ?? [:]
        var activeNow: Set<pid_t> = []
        for p in procs {
            let g = gpu[p.pid]?.t ?? 0
            defer { prevCPU[p.pid] = p.cpuNs; prevGPU[p.pid] = g }
            guard let oldCPU = prevCPU[p.pid] else { continue }   // 首拍只建基准
            let oldGPU = prevGPU[p.pid] ?? g
            let dCPU = Double(p.cpuNs >= oldCPU ? p.cpuNs - oldCPU : 0) / 1_000_000_000
            let dGPU = Double(max(0, g - oldGPU)) / 1_000_000_000
            if dCPU >= activeThreshold || dGPU >= activeThreshold { activeNow.insert(p.pid) }
        }
        for pid in activeNow { lastActive[pid] = now }
        let alive = Set(procs.map { $0.pid })
        for pid in lastActive.keys.filter({ !alive.contains($0) }) { lastActive[pid] = nil }
        for pid in Set(prevCPU.keys).subtracting(alive) { prevCPU[pid] = nil; prevGPU[pid] = nil }

        func isRunning(_ pid: pid_t) -> Bool {
            guard let t = lastActive[pid] else { return false }
            return now.timeIntervalSince(t) <= activeWindow
        }

        // 4.2b 进程树索引：引擎可能是「父进程监听端口、子进程跑推理」的双层结构（Splash 1.4 就是）。
        //      按端口取到的 holder 只是空壳，内存与计算都在子进程里 ⇒ 整棵树一起算。
        var ppidMap: [pid_t: pid_t] = [:]
        var childrenOf: [pid_t: [pid_t]] = [:]
        for p in procs {
            ppidMap[p.pid] = p.ppid
            if p.ppid > 0 { childrenOf[p.ppid, default: []].append(p.pid) }
        }
        func treePids(_ pid: pid_t) -> [pid_t] {
            var out: [pid_t] = [pid]
            var i = 0
            while i < out.count, out.count < 64 {
                out.append(contentsOf: childrenOf[out[i]] ?? [])
                i += 1
            }
            return out
        }
        func procMem(_ pid: pid_t) -> UInt64 {
            if let p = procs.first(where: { $0.pid == pid }) { return p.memBytes }
            return rusageOf(pid)?.mem ?? 0
        }
        func treeMemBytes(_ pid: pid_t) -> UInt64 {
            treePids(pid).reduce(0) { $0 + procMem($1) }
        }
        func treeRunning(_ pid: pid_t) -> Bool {
            treePids(pid).contains { isRunning($0) }
        }

        // 4.3 端口探测（进程端口 ∪ 已知端口表 ∪ 用户自定义端口）
        // portsOnly（自检用）：只探 extraPorts，把本机真在跑的引擎排除掉，让回归测试的断言只由 fixture 决定。
        var portsToScan = portsOnly ? Set(extraPorts) : Set(EngineWatcher.knownEngines.keys)
        portsToScan.formUnion(extraPorts)
        if !portsOnly { for p in procs { portsToScan.formUnion(p.ports) } }
        snap.scannedPorts = portsToScan.sorted()

        var hits: [EngineHit] = []
        // 端口 → 进程识别出来的引擎名：端口不在兜底表里、但进程认得（自定义端口很常见）时，
        // 用进程名给引擎起名，别一律叫「本地模型服务」。
        var kindByPort: [Int: String] = [:]
        for p in procs { for port in p.ports where kindByPort[port] == nil { kindByPort[port] = p.kind } }
        for port in snap.scannedPorts {
            guard LocalHTTP.connectable(port: port) else { continue }
            let hint = kindByPort[port] ?? adapters.ports[port]
                ?? EngineWatcher.knownEngines[port] ?? "本地模型服务"
            if let hit = detectEngine(port: port, hint: hint) {
                hits.append(hit)
                snap.enginesFound += 1
            } else if kindByPort[port] != nil || extraPorts.contains(port) {
                // 端口在应答，但试过的接口没有一个形状认得出来 ⇒ 占一行「待确认」，绝不静默丢弃（R6）。
                // 只在**有证据说它是模型引擎**时才列：进程认得出来，或用户显式声明了这个端口。
                // （兜底端口表本身只是猜测 —— 系统服务也会占默认端口，那不该变成一行噪音。）
                var h = EngineHit(kind: hint, port: port)
                h.adapter = "unknown"
                h.uncertain = true
                h.evidenceNote = "端口在应答，但载荷形状不认识（已试 /v1/models、/api/ps、/api/v0/models、"
                    + "/sdapi/v1/options、/queue）"
                hits.append(h)
                snap.enginesFound += 1
            }
        }

        // 4.4 合并：端口上的引擎 → 行
        var claimed: Set<pid_t> = []
        var pidUse: [pid_t: Int] = [:]

        /// 该进程的祖先是否已被某个端口行认领（内存/活动已在那一行算过，不要再列一遍）
        func underClaimed(_ pid: pid_t) -> Bool {
            var cur = pid, hops = 0
            while hops < 32 {
                guard let par = ppidMap[cur], par > 0 else { return false }
                if claimed.contains(par) { return true }
                cur = par
                hops += 1
            }
            return false
        }

        func append(pid: pid_t?, name: String, mem: UInt64, state: ModelState, note: String) {
            if let p = pid { pidUse[p, default: 0] += 1 }
            snap.rows.append(ModelRow(name: name, memGB: Double(mem) / 1_073_741_824,
                                      state: state, note: note, pid: pid))
        }

        for hit in hits {
            let holder = procs.first { $0.ports.contains(hit.port) }
            // 进程树聚合：Splash 1.4 的权重与计算都在 serve-native 子进程里，父进程只是 HTTP 壳
            // （只按端口取 holder 会报出 0.41 GB / 挂载待机，而实际是 27 GB 在解码）。
            let running = holder.map { treeRunning($0.pid) } ?? false
            let memBytes = holder.map { treeMemBytes($0.pid) } ?? 0
            if let h = holder { claimed.insert(h.pid) }

            let engineTag = hit.kind == "本地模型服务" ? "端口 \(hit.port)" : "\(hit.kind) · 端口 \(hit.port)"
            if hit.loaded.isEmpty && hit.loading.isEmpty && hit.failed.isEmpty && hit.reported.isEmpty {
                // 引擎活着但没加载任何模型：仍然列出来（用户需要知道它占着端口）。
                // 证据不足时显示「待确认」并写明看到什么，不硬说「没有加载模型」（R2）。
                append(pid: holder?.pid, name: hit.kind, mem: memBytes,
                       state: hit.uncertain ? .uncertain : (running ? .running : .idle),
                       note: "pid \(holder?.pid ?? 0) · \(engineTag) · "
                           + (hit.uncertain ? hit.evidenceNote : "没有加载模型"))
            } else {
                var first = true
                for name in hit.loaded {
                    // 服务自己报了该模型的常驻字节就用它（同一进程里多模型时，进程内存在这里是合计）
                    let own = hit.resident[name].map { UInt64($0) }
                    let detail: String
                    if hit.loaded.count > 1 {
                        detail = own != nil
                            ? "同一进程托管 \(hit.loaded.count) 个模型，此处是该模型自己报的常驻字节"
                            : "同一进程托管 \(hit.loaded.count) 个模型，内存是合计"
                    } else {
                        detail = running ? "正在处理请求" : "权重在内存、无计算"
                    }
                    append(pid: first ? holder?.pid : nil, name: name, mem: own ?? memBytes,
                           state: running ? .running : .idle,
                           note: "pid \(holder?.pid ?? 0) · \(engineTag) · \(detail)")
                    first = false
                }
                // 加载中：权重正在往内存里搬（大模型要几十秒到几分钟），这时服务还接不了请求，
                // 但绝不能报成「没有加载模型」—— 那看着就像没识别到这个模型
                for name in hit.loading {
                    let own = hit.resident[name].map { UInt64($0) }
                    append(pid: first ? holder?.pid : nil, name: name, mem: own ?? memBytes,
                           state: .loading,
                           note: "pid \(holder?.pid ?? 0) · \(engineTag) · 权重正在加载，暂不接请求")
                    first = false
                }
                for name in hit.failed {
                    append(pid: first ? holder?.pid : nil, name: name, mem: 0,
                           state: .failed,
                           note: "pid \(holder?.pid ?? 0) · \(engineTag) · 该模型加载失败（服务端日志有原因）")
                    first = false
                }
                // 引擎自报了状态、但我们映射不了：原样显示，不并进「未加载」（R3）
                for (name, raw) in hit.reported.sorted(by: { $0.key < $1.key }) {
                    let own = hit.resident[name].map { UInt64($0) }
                    append(pid: first ? holder?.pid : nil, name: name, mem: own ?? memBytes,
                           state: .uncertain,
                           note: "pid \(holder?.pid ?? 0) · \(engineTag) · 引擎自报状态「\(raw)」，"
                               + "这个值我们还不认识（原样显示，不当作未加载）")
                    first = false
                }
            }
            snap.unloaded.append(contentsOf: hit.unloaded)
        }

        // 4.5 端口没覆盖到的模型进程（应用内模型 / 自定义端口 / 正在退出的旧实例）
        var orphanMem: [pid_t: (bytes: UInt64, count: Int)] = [:]
        for p in procs where !claimed.contains(p.pid) {
            // 祖先已被某个端口行认领（Splash 的 serve-native 就挂在 python 父进程下）：
            // 内存与活动已经并进那一行，这里不再重复列出
            if underClaimed(p.pid) { continue }
            if p.ports.isEmpty,
               let sib = procs.first(where: { $0.pid != p.pid && $0.kind == p.kind && !$0.ports.isEmpty }) {
                // 引擎重启的过渡态：内存并到服务中的那一行，不重复列
                let cur = orphanMem[sib.pid] ?? (0, 0)
                orphanMem[sib.pid] = (cur.bytes + p.memBytes, cur.count + 1)
                continue
            }
            let running = isRunning(p.pid)
            let livePort = p.ports.first { LocalHTTP.connectable(port: $0) }
            var state: ModelState
            var note: String
            if let port = livePort {
                state = running ? .running : .idle
                note = "pid \(p.pid) · 端口 \(port) · " + (running ? "正在处理请求" : "权重在内存、无计算")
            } else if p.ports.isEmpty {
                state = running ? .running : .idle
                note = "pid \(p.pid) · 应用内模型，无服务端口"
            } else {
                state = .failed
                note = "pid \(p.pid) · 端口 \(p.ports.map(String.init).joined(separator: "/")) 连不上"
            }
            append(pid: p.pid, name: p.display, mem: p.memBytes, state: state, note: note)
        }

        // 4.5b 引擎声明的权重目录（清单层要用）
        var dirSet = Set<String>()
        for p in procs { for d in p.modelDirs { dirSet.insert(d) } }
        snap.modelDirs = dirSet.sorted()

        // 4.6 收尾：退出中实例的内存并回在服务的那一行；排序；共享标记
        for (pid, extra) in orphanMem {
            guard let idx = snap.rows.firstIndex(where: { $0.pid == pid }) else { continue }
            snap.rows[idx].memGB += Double(extra.bytes) / 1_073_741_824
            snap.rows[idx].note += "（另含 \(extra.count) 个退出中的旧实例内存）"
        }
        snap.rows.sort { $0.memGB > $1.memGB }
        for i in snap.rows.indices {
            if let p = snap.rows[i].pid, (pidUse[p] ?? 0) > 1 { snap.rows[i].shared = true }
        }
        snap.unloaded = Array(Set(snap.unloaded)).sorted()

        prevAt = now
        return snap
    }
}
