nonisolated enum CountCopy {
    static func hits(_ total: Int) -> String { String(localized: "\(total) 条") }

    static func more(_ left: Int) -> String { String(localized: "显示更多（还有 \(left) 条）") }

    static func items(_ count: Int) -> String? { count > 0 ? hits(count) : nil }
}
