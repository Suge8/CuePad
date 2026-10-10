/// 计数的写法："25 条灵感 · 3 项任务"——为 0 的那项不写，全是 0 时整句不写（nil）：0 是噪音，眼睛要先读到再把它排除。
nonisolated enum CountCopy {
    static func text(_ counts: (count: Int, unit: String)...) -> Dotted? {
        Dotted(counts.filter { $0.count > 0 }.map { "\($0.count) \($0.unit)" }).nonEmpty
    }
}
