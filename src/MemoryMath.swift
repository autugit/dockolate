// ============================================================
// 内存口径（v1.6.1）
// ============================================================
//
// macOS 26/27 上，Metal 的显存是「匿名页 + wired」：同一批页既被算进
// `internal_page_count`（匿名、resident），也被算进 `wire_count`。
// 于是「应用 + 联动 + 压缩」三项相加会**超过物理内存**——本机实测出现过
// 合计超过物理内存的情况，界面上「可用」永远是 0，管理器把所有模型都判成放不下。
//
// 规则：先按老口径（活动监视器式：应用 + 联动 + 压缩）算；**只有当它超过物理内存时**
// 才认为出现重复计数，改用去重口径 max(应用, 联动) + 压缩。
// 物理内存是硬上限，超过它的一定是口径问题，不是真的用了那么多。

enum MemoryMath {
    /// 返回 (已用 GB, 是否启用了去重口径)
    static func usedGB(internalGB: Double, wiredGB: Double, compressedGB: Double,
                       totalGB: Double) -> (used: Double, deduped: Bool) {
        guard totalGB > 0 else { return (0, false) }
        let classic = internalGB + wiredGB + compressedGB
        if classic <= totalGB { return (min(classic, totalGB), false) }
        let deduped = max(internalGB, wiredGB) + compressedGB
        return (min(deduped, totalGB), true)
    }
}
