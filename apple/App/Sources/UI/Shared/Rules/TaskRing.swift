import CueStore

/// 任务的完成圈怎么画（任务行、任务页、Mac 面板同一条规则）：没有下级是普通圆圈；有下级时每条提示词、每个子任务各占一段，
/// 那一段做完（提示词已回复、子任务完成，见 `ChildMark`）就满；下级多到一段太窄时改成按比例的一道弧。
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
