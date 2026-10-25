/// 计数的写法：为 0 时不写（nil）——0 是噪音，眼睛要先读到再把它排除。
nonisolated enum CountCopy {
    /// 搜索命中数："3 条"，iPhone 与 Mac 同一种写法。
    static func hits(_ total: Int) -> String { String(localized: "\(total) 条") }

    /// 分页列表末尾再读一页的那颗钮（搜索、选一条灵感或任务）。
    static func more(_ left: Int) -> String { String(localized: "显示更多（还有 \(left) 条）") }

    /// 一组里有几条（回收站里项目带进来的卡片）。
    static func items(_ count: Int) -> String? { count > 0 ? hits(count) : nil }
}
