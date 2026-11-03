// ============================================================
// 管理器逻辑自检（--self-test-manager）
// ============================================================
//
// 这些是「不靠界面也能验」的判据：分类、内存估算、三色可行性、工作组求和、
// 配方匹配、两种日志/指标解析。跑法：`bash tests/verify_manager.sh`
// 断言用合成数据，不依赖本机真的跑着哪个引擎。

import Cocoa

final class SelfTest {
    private var pass = 0
    private var fail = 0

    private func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond { pass += 1; print("  ✓ \(name)\(detail.isEmpty ? "" : "（\(detail)）")") }
        else { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "（\(detail)）")") }
    }

    private func eq(_ name: String, _ got: Double, _ want: Double, tol: Double = 0.01) {
        check(name, abs(got - want) <= tol, String(format: "%.3f ≈ %.3f", got, want))
    }

    private func eqS(_ name: String, _ got: String, _ want: String) {
        check(name, got == want, "得到「\(got)」")
    }

    func run() -> Int {
        print("== 分类 ==")
        eqS("对话模型 → chat", ModelClassifier.classify(
            name: "My-Chat-Model-27B-4bit", path: "/m/my-chat-model", role: .main,
            categoryHint: nil).rawValue, "chat")
        eqS("Qwen-Image → image", ModelClassifier.classify(
            name: "Qwen-Image-2.1", path: "/m/Qwen-Image-2.1/transformer", role: .main,
            categoryHint: nil).rawValue, "image")
        eqS("Wan2.2-I2V → video", ModelClassifier.classify(
            name: "Wan2.2-I2V-A14B", path: "/m/wan", role: .main, categoryHint: nil).rawValue, "video")
        eqS("Embedding → embedding", ModelClassifier.classify(
            name: "Qwen3-Embedding-0.6B", path: "/m/emb", role: .main,
            categoryHint: nil).rawValue, "embedding")
        eqS("whisper → audio", ModelClassifier.classify(
            name: "whisper-large-v3", path: "/m/whisper", role: .main,
            categoryHint: nil).rawValue, "audio")
        eqS("草稿头 → part", ModelClassifier.classify(
            name: "My-Chat-Model-27B-DFlash2", path: "/m/dflash", role: .mtp,
            categoryHint: nil).rawValue, "part")
        eqS("配方显式声明优先", ModelClassifier.classify(
            name: "whatever", path: "/m/x", role: .main, categoryHint: "image").rawValue, "image")

        print("== 内存估算 ==")
        let chat = MemoryEstimator.estimate(weightsGB: 16.0, category: .chat, observedGB: nil)
        eq("对话：权重 + 15% 开销", chat.gb, 18.4)
        check("估算依据写清权重与开销", chat.basis.contains("权重 16.0") && chat.basis.contains("开销估算 2.4"),
              chat.basis)
        let observed = MemoryEstimator.estimate(weightsGB: 16.0, category: .chat, observedGB: 26.4)
        eq("有实测峰值就用实测", observed.gb, 26.4)
        check("实测依据标注", observed.basis.contains("实测峰值"), observed.basis)
        let tiny = MemoryEstimator.estimate(weightsGB: 1.0, category: .chat, observedGB: 0.4)
        check("实测比估算小时仍按估算（防止加载中读到的半截）", tiny.gb >= 1.0 + 2.0 - 0.001,
              String(format: "%.2f", tiny.gb))

        print("== 三色可行性 ==")
        let budget = MemoryBudget(totalGB: 96, usedGB: 42.6, reserveGB: 6)   // 可用 47.4
        eq("可用内存 = 总 − 已用 − 余量", budget.availableGB, 47.4)
        eqS("30 GB → 宽裕（≤ 可用×85%）", MemoryBudget.fit(estGB: 30, budget: budget).text(canLaunch: true), "可拉起")
        eqS("45 GB → 勉强（≤ 可用）", MemoryBudget.fit(estGB: 45, budget: budget).text(canLaunch: true), "勉强够")
        eqS("60 GB → 放不下", MemoryBudget.fit(estGB: 60, budget: budget).text(canLaunch: true), "内存不足")
        eqS("没配方时不说「可拉起」", MemoryBudget.fit(estGB: 30, budget: budget).text(canLaunch: false), "内存够")
        eqS("估算为 0（部件）→ 不可单独起",
             MemoryBudget.fit(estGB: 0, budget: budget).text(canLaunch: false), "不可单独起")
        let tight = MemoryBudget(totalGB: 96, usedGB: 92, reserveGB: 6)
        eq("已用 + 余量超过总量时可用为 0（不出现负数）", tight.availableGB, 0, tol: 0.0001)

        print("== 配方 ==")
        let recipe = LaunchRecipe.parse([
            "id": "x", "title": "X", "engine": "MyEngine", "port": 12345,
            "modelPatterns": ["My-Chat-Model-27B"], "path": "/m/my-chat-model",
            "start": "/bin/echo start", "stop": ["/bin/echo", "stop"],
            "log": "~/logs/x.log", "metrics": "prometheus", "estMemGB": 26,
        ])!
        check("字符串命令按 shell 解析", recipe.start?.isShell == true && recipe.start?.argv[0] == "/bin/bash")
        check("数组命令按 argv 解析", recipe.stop?.isShell == false && recipe.stop?.argv == ["/bin/echo", "stop"])
        check("log 的 ~ 展开", recipe.log?.hasPrefix(NSHomeDirectory()) == true)
        eq("estMemGB 解析", recipe.estMemGB ?? 0, 26)
        check("按路径相等匹配", recipe.matches(name: "别的名字", path: "/m/my-chat-model", engine: nil, port: nil))
        check("按名字匹配", recipe.matches(name: "My-Chat-Model-27B-4bit", path: nil, engine: nil, port: nil))
        check("按引擎+端口匹配", recipe.matches(name: "x", path: nil, engine: "MyEngine", port: 12345))
        check("引擎相同但端口不同不匹配", !recipe.matches(name: "x", path: nil, engine: "MyEngine", port: 9000))
        check("HF 缓存里的同名副本不算同一个（路径不同、名字只在路径里）",
              !recipe.matches(name: "localfourbit",
                              path: NSHomeDirectory() + "/.cache/huggingface/hub/models--o--My-Chat-Model-27B/snapshots/x",
                              engine: nil, port: nil))

        print("== Splash 日志解析 ==")
        let splash = SplashLogProfile()
        splash.reset()
        splash.consume("Ready · model · context 256K · http://127.0.0.1:8000")
        splash.consume("Done · input 4,184 · cached 0 · output 900 · TTFT 3.5s · 74.0 tok/s · 2.1 tok/cycle")
        splash.consume("Done · input 805 · cached 672 · output 71 · TTFT 0.2s · 48.4 tok/s · 4.1 tok/cycle")
        splash.consume("Error · not_found · GET /api/ps")
        splash.consume("Done · input 1,000 · cached 0 · output 100 · TTFT 1.0s · 50.0 tok/s · 2.0 tok/cycle")
        eq("请求数", Double(splash.totals.requests), 3)
        eq("输入 token 合计", Double(splash.totals.tokensIn), 4184 + 805 + 1000)
        eq("输出 token 合计", Double(splash.totals.tokensOut), 900 + 71 + 100)
        // decode = Σoutput ÷ Σ(output ÷ 每请求速率)
        eq("平均 decode（按 token 加权）", splash.totals.decodeTokS ?? 0,
           1071.0 / (900 / 74.0 + 71 / 48.4 + 100 / 50.0), tol: 0.2)
        // prefill 只算「新读进来」的 token：4184 + (805-672) + 1000，秒数取 TTFT 之和
        eq("平均 prefill（剔除缓存命中）", splash.totals.prefillTokS ?? 0,
           Double(4184 + 133 + 1000) / (3.5 + 0.2 + 1.0), tol: 0.5)

        print("== Strata /metrics（JSON）解析 ==")
        let json: [String: Any] = [
            "since": Date().timeIntervalSince1970 - 600,
            "totals": ["requests": 3, "prompt_tokens": 3000, "output_tokens": 600,
                       "prompt_ms": 1500, "decode_ms": 6000],
            "requests": [
                ["prompt_tokens": 1000, "prompt_read": 1000, "prompt_ms": 500,
                 "output_tokens": 200, "decode_ms": 2000],
                ["prompt_tokens": 1000, "prompt_read": 100, "prompt_ms": 100,
                 "output_tokens": 200, "decode_ms": 2000],
                ["prompt_tokens": 1000, "prompt_read": 900, "prompt_ms": 900,
                 "output_tokens": 200, "decode_ms": 2000],
            ],
        ]
        if let m = JSONMetrics.parse(json) {
            eq("prefill 用 prompt_read ÷ prompt_ms", m.prefillTokS ?? 0, 2000.0 / 1.5, tol: 0.5)
            eq("decode 用 output ÷ decode_ms", m.decodeTokS ?? 0, 600.0 / 6.0, tol: 0.5)
            eq("请求数", Double(m.requests), 3)
            eq("输入 token", Double(m.tokensIn), 3000)
            eq("输出 token", Double(m.tokensOut), 600)
            check("运行时间来自 since", (m.uptime ?? 0) > 590 && (m.uptime ?? 0) < 610,
                  String(format: "%.0f s", m.uptime ?? 0))
        } else {
            check("JSON 指标能解析", false)
        }
        check("不是 Strata 形状的 JSON 不认", JSONMetrics.parse(["foo": 1]) == nil)

        print("== 目录归组与对账 ==")
        // 真实形态：主权重在 `<模型目录>/transformer`，部件在同级 vae / text_encoder 下
        var mainID = ModelIdentity()
        mainID.family = "Qwen-Image-2.1"
        mainID.quant = "8bit"
        mainID.role = .main
        mainID.bytes = 16 * 1_073_741_824
        mainID.files = 3
        var partID = ModelIdentity()
        partID.family = "Qwen-Image-2.1"
        partID.role = .vae
        partID.bytes = 3 * 1_073_741_824
        partID.files = 1
        let units = [
            DiskUnit(path: "~/models/Qwen-Image-2.1/transformer", realPath: "/m/Qwen-Image-2.1/transformer",
                     source: "自定义目录", identity: mainID),
            DiskUnit(path: "~/models/Qwen-Image-2.1/vae", realPath: "/m/Qwen-Image-2.1/vae",
                     source: "自定义目录", identity: partID),
        ]
        let entries = ModelCatalog.build(units: units, runtime: ModelSnapshot(),
                                         config: LauncherConfig(), observed: ObservedMemory(),
                                         roots: ["/m"])
        check("同一目录下的草稿头并进主模型一行", entries.count == 1,
              "得到 \(entries.count) 行")
        if let e = entries.first {
            eq("盘占用按主 + 部件合计", e.diskGB, 19.0, tol: 0.05)
            check("分类为生图", e.category == .image, e.category.rawValue)
            check("没有配方就不可拉起", !e.canLaunch && e.blockedReason != nil, e.blockedReason ?? "")
        }

        print("== 内存口径（GPU 显存重复计数）==")
        let normal = MemoryMath.usedGB(internalGB: 20, wiredGB: 6, compressedGB: 2, totalGB: 96)
        eq("常规机器：应用 + 联动 + 压缩", normal.used, 28)
        check("常规机器不走去重", !normal.deduped)
        let gpu = MemoryMath.usedGB(internalGB: 61.5, wiredGB: 69.7, compressedGB: 7.7, totalGB: 96)
        eq("应用/联动超物理内存时去重（取较大者 + 压缩）", gpu.used, 77.4)
        check("去重标记置位", gpu.deduped)
        let capped = MemoryMath.usedGB(internalGB: 200, wiredGB: 200, compressedGB: 50, totalGB: 96)
        eq("永远不会超过物理内存", capped.used, 96)

        print("== 按钮可用性（拉起 / 卸载）==")
        var studio = ModelIdentity()
        studio.family = "Some-Chat-27B"
        studio.role = .main
        studio.bytes = 16 * 1_073_741_824
        studio.files = 3
        let soloUnits = [DiskUnit(path: "~/models/Some-Chat-27B", realPath: "/m/Some-Chat-27B",
                                  source: "用户模型目录", identity: studio)]
        var cfg = LauncherConfig()
        if let rec = LaunchRecipe.parse([
            "id": "solo", "title": "Some-Chat-27B", "path": "/m/Some-Chat-27B",
            "port": 12345, "start": "/bin/echo start", "stop": "/bin/echo stop",
        ]) { cfg.recipes = [rec] }
        let idleEntries = ModelCatalog.build(units: soloUnits, runtime: ModelSnapshot(),
                                             config: cfg, observed: ObservedMemory(), roots: ["/m"])
        check("未运行：可拉起", idleEntries.first?.canLaunch == true)
        check("未运行：**不能**卸载（有 stop 配方也不行）", idleEntries.first?.canStop == false,
              "canStop=\(idleEntries.first?.canStop ?? false)")
        var snap = ModelSnapshot()
        snap.rows = [ModelRow(name: "Some-Chat-27B", memGB: 20, state: .running, note: "",
                              port: 12345, engine: "MyEngine")]
        let liveEntries = ModelCatalog.build(units: soloUnits, runtime: snap,
                                             config: cfg, observed: ObservedMemory(), roots: ["/m"])
        check("运行中：可卸载", liveEntries.first?.canStop == true)
        check("运行中：不能重复拉起", liveEntries.first?.canLaunch == false)

        print("== 媒体指标（生图 / 视频：轮次 · 每轮耗时 · 当前这轮）==")
        let comfyR = LaunchRecipe.parse(["id": "c", "port": 12346, "media": "comfyui",
                                         "category": "service", "path": "/m/comfy"])
        check("comfyui 配方 → 图片媒体", comfyR?.mediaKind == .image)
        check("没声明 media 的配方不走媒体口径", recipe.mediaKind == nil, recipe.media ?? "nil")
        let vidR = LaunchRecipe.parse(["id": "v", "port": 12347, "media": "mlxserve",
                                       "category": "video", "modelPatterns": ["Some-Video-Model"]])
        check("mlxserve + video 配方 → 视频媒体", vidR?.mediaKind == .video)
        check("只有端口的配方按端口认领运行行（服务卡片不会再出两张）",
              comfyR?.matches(name: "ComfyUI", path: nil, engine: "ComfyUI", port: 12346) == true)
        check("端口不同不认领", comfyR?.matches(name: "ComfyUI", path: nil, engine: nil, port: 12346 + 1) == false)

        // ComfyUI /history：毫秒时间戳 → 轮次与每轮耗时
        let history: [String: Any] = [
            "a": ["status": ["messages": [["execution_start", ["timestamp": 1_790_000_000_000.0]],
                                          ["execution_success", ["timestamp": 1_790_000_044_600.0]]]]],
            "b": ["status": ["messages": [["execution_start", ["timestamp": 1_790_000_100_000.0]],
                                          ["execution_success", ["timestamp": 1_790_000_143_700.0]]]]],
            "c": ["status": ["messages": [["execution_start", ["timestamp": 1_790_000_200_000.0]],
                                          ["execution_error", ["timestamp": 1_790_000_201_000.0]]]]],
        ]
        let h = ComfyMediaProbe.parseHistory(history)
        eq("轮次只算成功出图", Double(h.rounds), 2)
        eq("失败 / 中断单独计", Double(h.failed), 1)
        eq("第 1 轮 44.6 秒", h.durations.first ?? 0, 44.6, tol: 0.05)
        eq("第 2 轮 43.7 秒", h.durations.last ?? 0, 43.7, tol: 0.05)

        // 一轮批量出多张：数 outputs 里的图，temp 预览不算
        let batch: [String: Any] = [
            "a": ["status": ["messages": [["execution_start", ["timestamp": 1_790_000_000_000.0]],
                                          ["execution_success", ["timestamp": 1_790_000_040_000.0]]]],
                  "outputs": ["9": ["images": [["filename": "a.png", "type": "output"],
                                               ["filename": "b.png", "type": "output"],
                                               ["filename": "c.png", "type": "temp"]]]]],
        ]
        let bh = ComfyMediaProbe.parseHistory(batch)
        eq("一轮批量出 2 张（temp 预览不算）", Double(bh.images), 2)
        eqS("一轮多张时的文案", mediaSummaryLine(MediaMetric(kind: .image, rounds: 1, products: 2,
                                                        durations: [40])).first ?? "",
            "已出 1 轮 · 2 张")

        // mlx-serve 日志：一轮的开始 / 步进度 / 出片
        let mp = MlxServeMediaProbe(kind: .video, logPath: "/tmp/不存在的日志", port: 18080)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        mp.feedForTest("[minimax-h3] 576x384 124 frames (37 latent, 207 audio), 20 steps", now: t0)
        mp.feedForTest("[minimax-h3] step 12/20 sigma 0.9076 (2781 ms)", now: t0.addingTimeInterval(40))
        let mid = mp.snapshotForTest(at: t0.addingTimeInterval(40))
        eq("当前这轮已用 40 秒", mid.currentElapsedS ?? -1, 40, tol: 0.5)
        eq("步进度", Double(mid.currentStep ?? -1), 12)
        eq("总步数", Double(mid.currentStepTotal ?? -1), 20)
        check("还没出片就不算一轮", mid.rounds == 0)
        mp.feedForTest("[video] -> 124f 584x384 (82280448 rgb bytes)", now: t0.addingTimeInterval(78))
        let finished = mp.snapshotForTest(at: t0.addingTimeInterval(78))
        eq("出片后轮次 +1", Double(finished.rounds), 1)
        eq("这一轮 78 秒", finished.lastS ?? -1, 78, tol: 0.5)
        check("出片后当前没有任务", finished.currentElapsedS == nil)
        eq("帧数", Double(finished.lastFrames ?? 0), 124)
        eqS("分辨率", finished.lastSize ?? "", "584×384")

        // 观测不到起点的那一轮：只计轮次、不进平均（界面据实写「耗时未观测」）
        let old = MlxServeMediaProbe(kind: .video, logPath: "/tmp/不存在的日志", port: 18080)
        old.feedForTest("[minimax-h3] 576x384 124 frames (0 latent, 0 audio), 20 steps",
                        now: t0, adoptAsHistorical: true)
        old.feedForTest("[video] -> 124f 576x384 (0 rgb bytes)", now: t0.addingTimeInterval(78))
        let adopted = old.snapshotForTest(at: t0.addingTimeInterval(78))
        check("历史轮次计入轮次但**不记耗时**", adopted.rounds == 1 && adopted.durations.isEmpty,
              "轮次 \(adopted.rounds) / 耗时 \(adopted.durations.count)")

        // 文案口径
        eqS("9.4 秒 → 一位小数", mediaSeconds(9.4), "9.4 秒")
        eqS("45.6 秒 → 取整", mediaSeconds(45.6), "46 秒")
        eqS("130 秒 → 分秒", mediaSeconds(130), "2 分 10 秒")
        let demoMedia = MediaMetric(kind: .image, rounds: 2, durations: [43.7, 45.9],
                                    currentElapsedS: 12, currentIndex: 3)
        eqS("摘要 = 几张 · 每张多久 · 当前这张",
            mediaSummaryLine(demoMedia).joined(separator: " | "),
            "已出 2 张 | 平均 44.8 秒/张 | 当前第 3 张 12 秒")

        print("== 名称归一 ==")
        check("版本点不被当扩展名吃掉", normName("My-Chat-Model-27B-4bit-MTP") == "mychatmodel27b4bitmtp",
              normName("My-Chat-Model-27B-4bit-MTP"))
        check("权重扩展名剥掉", normName("model-Q4_K_M.gguf") == "modelq4km")

        print("")
        print(fail == 0 ? "全部通过：\(pass) 条" : "失败 \(fail) 条 / 共 \(pass + fail) 条")
        return fail == 0 ? 0 : 1
    }
}
