import CueStore

/// 任务的完成圈怎么画（任务行、浮窗、Mac 面板同一条规则）：没有下级是普通圆圈；有下级时每个子任务、每条挂着的灵感各占一段，
/// 那一段做完（子任务完成、灵感交给过 Agent，见 `ChildMark`）就满；下级多到一段太窄时改成按比例的一道弧。
nonisolated enum TaskRing: Equatable, Sendable {
    case plain
    case segments([Bool])
    case fraction(done: Int, total: Int)

    /// 一圈最多分几段：再多每段窄得看不清，改按比例画。
    static let maxSegments = 12

    init(_ marks: [ChildMark]?) {
        guard let marks, !marks.isEmpty else { self = .plain; return }
        let done = marks.map(\.isDone)
        self = marks.count <= Self.maxSegments ? .segments(done) : .fraction(done: done.filter { $0 }.count, total: marks.count)
    }

    /// 读屏："下级 3/5 已完成"；普通圆圈没有。
    var speech: String? {
        switch self {
        case .plain: nil
        case .segments(let done): "下级 \(done.filter { $0 }.count)/\(done.count) 已完成"
        case .fraction(let done, let total): "下级 \(done)/\(total) 已完成"
        }
    }
}

/// 交给 Agent 的正文：任务的话在前，选中的灵感（挂着的相关灵感、本项目资料）各自变量已填，依次接在后面，用分隔线隔开。
nonisolated enum TaskBundle {
    static let separator = "\n\n---\n\n"

    static func text(task: String, parts: [Card]) -> String {
        ([task] + parts.map { Outgoing.text(of: $0) }).joined(separator: separator)
    }
}
