import CueStore

/// 任务的完成圈怎么画（任务行、任务页、Mac 面板同一条规则）：没有下级是只看状态的圆圈；有下级时圈的右半另画进度，
/// 按做完的下级（提示词已回复、子任务完成，见 `ChildMark`）占的比例从 12 点顺时针填淡色（画法见 `TaskRingView`）。
nonisolated enum TaskRing: Equatable, Sendable {
    case plain
    case progress(done: Int, total: Int)

    init(_ marks: [ChildMark]?) {
        guard let marks, !marks.isEmpty else { self = .plain; return }
        self = .progress(done: marks.filter(\.isDone).count, total: marks.count)
    }

    /// 读屏："下级 3/5 已完成"；普通圆圈没有。
    var speech: String? {
        guard case .progress(let done, let total) = self else { return nil }
        return "下级 \(done)/\(total) 已完成"
    }
}
