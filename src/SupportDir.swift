// ============================================================
// 可写状态目录（单一入口）
// ============================================================
//
// 程序本体（.app bundle，可能装在 /Applications 且由 root 拥有）与**可写状态**必须彻底分开：
//   · 状态：~/Library/Application Support/Dockolate/（registry / launchers / workgroups /
//     observed / engines / adapters 覆盖层 / hub-state）
//   · 本文件是唯一取状态的入口 —— 任何新代码都写 SupportDir.dir，不要自己拼路径。
//
// `DOCKOLATE_SUPPORT_DIR` 可覆盖（测试/多实例用）：`tests/verify_api.sh` 靠它把
// 全部写操作挡在临时目录里，绝不碰用户真实配置。

import Foundation

enum SupportDir {
    static var dir: String {
        if let o = ProcessInfo.processInfo.environment["DOCKOLATE_SUPPORT_DIR"], !o.isEmpty {
            return (o as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/Library/Application Support/Dockolate"
    }

    static func path(_ name: String) -> String { dir + "/" + name }

    static var registry: String { path("registry.json") }
    static var launchers: String { path("launchers.json") }
    static var workgroups: String { path("workgroups.json") }
    static var observed: String { path("observed.json") }
    static var engines: String { path("engines.json") }
    static var adaptersOverride: String { path("adapters.json") }
    static var hubState: String { path("hub-state.json") }

    /// 确保目录存在（写文件前调一次；失败不致命，写操作自己会报错）
    @discardableResult
    static func ensure() -> Bool {
        (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil
    }
}
