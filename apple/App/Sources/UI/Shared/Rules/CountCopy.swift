/// 计数的写法："25 条灵感 · 3 项任务"——为 0 的那项不写，全是 0 时整句不写（nil）：0 是噪音，眼睛要先读到再把它排除。
nonisolated enum CountCopy {
    /// 搜索命中数："3 条"，iPhone 与 Mac 同一种写法。
    static func hits(_ total: Int) -> String { "\(total) 条" }

    /// 分页列表末尾再读一页的那颗钮（搜索、选一条灵感或任务）。
    static func more(_ left: Int) -> String { "显示更多（还有 \(left) 条）" }

    static func text(_ counts: (count: Int, unit: String)...) -> Dotted? {
        Dotted(counts.filter { $0.count > 0 }.map { "\($0.count) \($0.unit)" }).nonEmpty
    }
}
