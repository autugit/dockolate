// ============================================================
// 适配器签名表（方案 M4）
// ============================================================
//
// 目的：**新引擎/新状态串不用等应用发版**。把「纯数据」的那几层放到 JSON 里：
//
//   processHints  { "进程特征词": "显示名" }       —— 进程指纹 → 引擎名
//   ports         { "端口": "显示名" }            —— 兜底端口表（只在进程认不出时用）
//   states        { "引擎自报的状态串": "档" }     —— 状态词表（res看下）
//   roles         { "文件名/目录特征词": "角色" }   —— 部件识别（草稿头 / 投影 / LoRA / VAE …）
//   probePaths    [ "/自定义状态接口", … ]         —— 诊断报告里额外试的路径
//
// 两份来源按顺序叠加（后者覆盖前者）：
//   ① 应用内置 `Contents/Resources/adapters.json`
//   ② 用户覆盖 `~/Library/Application Support/Dockolate/adapters.json`
//   ③ 环境变量 `DOCKOLATE_ADAPTERS=<路径>`（测试与排障用，优先级最高）
//
// 解析失败**绝不致命**：记一条警告、继续用能用的部分（远端/用户手改的文件出错的概率不低）。

import Foundation

struct AdapterTable {
    /// 进程特征词 → 显示名（用户条目排在前面，且同长度时按字母序，保证可复现）
    var processHints: [(keyword: String, name: String)] = []
    /// 端口 → 显示名（仅兜底）
    var ports: [Int: String] = [:]
    /// 状态串 → 档位（resident / loading / failed / absent）
    var states: [String: ModelBucketName] = [:]
    /// 特征词 → 角色
    var roles: [String: String] = [:]
    /// 额外探测路径（进 --probe / 发现报告）
    var probePaths: [String] = []
    /// 解析过程中收集的问题（给 --check-adapters 看，不打断运行）
    var warnings: [String] = []
    /// 每份来源是否成功加载（诊断用）
    var sources: [(path: String, ok: Bool, entries: Int)] = []

    enum ModelBucketName: String {
        case resident, loading, failed, absent
    }

    /// 进程内只加载一次（三份来源叠加后的结果）
    static let shared = AdapterTable.load()

    static let userPath = NSHomeDirectory() + "/Library/Application Support/Dockolate/adapters.json"

    /// 内置 + 用户 + 环境变量，依次叠加
    static func load() -> AdapterTable {
        var t = AdapterTable()
        var paths: [String] = []
        if let bundled = Bundle.main.path(forResource: "adapters", ofType: "json") {
            paths.append(bundled)
        }
        // 直接跑 build/ 里的可执行文件时，Bundle.main 就是 .app，上面那步已经命中；
        // 万一有人把二进制单拎出来跑，再试一次相对路径，便于开发调试。
        if paths.isEmpty {
            let guess = (CommandLine.arguments.first as NSString?)?.deletingLastPathComponent ?? "."
            let rel = guess + "/../Resources/adapters.json"
            if FileManager.default.fileExists(atPath: rel) { paths.append(rel) }
        }
        paths.append(userPath)
        if let env = ProcessInfo.processInfo.environment["DOCKOLATE_ADAPTERS"], !env.isEmpty {
            paths.append((env as NSString).expandingTildeInPath)
        }
        for p in paths { t.merge(path: p) }
        return t
    }

    private mutating func merge(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            warnings.append("读不了：\(path)")
            sources.append((path, false, 0))
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // 用户手改坏 JSON 是最常见的事故，必须只警告不崩
            warnings.append("不是合法 JSON 对象：\(path)")
            sources.append((path, false, 0))
            return
        }
        var entries = 0

        if let hints = obj["processHints"] as? [String: String] {
            var incoming: [(String, String)] = []
            for (k, v) in hints where !k.isEmpty && !v.isEmpty {
                incoming.append((k.lowercased(), v))
                entries += 1
            }
            // 长的特征词优先（更具体），再按字母序，避免执行顺序影响结果
            incoming.sort { a, b in
                a.0.count != b.0.count ? a.0.count > b.0.count : a.0 < b.0
            }
            // 叠加到最前：用户表能覆盖内置表
            processHints = incoming + processHints
        }

        if let ports = obj["ports"] as? [String: String] {
            for (k, v) in ports {
                if let p = Int(k), p > 0, p < 65536, !v.isEmpty { self.ports[p] = v; entries += 1 }
                else { warnings.append("ports 里的键不是端口：\(k)") }
            }
        }

        if let states = obj["states"] as? [String: String] {
            for (k, v) in states where !k.isEmpty {
                if let b = ModelBucketName(rawValue: v.lowercased()) {
                    self.states[k.lowercased()] = b
                    entries += 1
                } else {
                    warnings.append("states 里的档位不认识：\(k) → \(v)（只能是 resident/loading/failed/absent）")
                }
            }
        }

        if let roles = obj["roles"] as? [String: String] {
            for (k, v) in roles where !k.isEmpty {
                self.roles[k.lowercased()] = v
                entries += 1
            }
        }

        if let paths = obj["probePaths"] as? [String] {
            for p in paths where p.hasPrefix("/") {
                if !probePaths.contains(p) { probePaths.append(p); entries += 1 }
            }
        }

        sources.append((path, true, entries))
    }
}
