import CueStore

/// 任务的完成圈怎么画（任务行、任务页、Mac 面板同一条规则）：没有下级是只看状态的圆圈；有下级、还没全做完时圈下多一条细的进度条，
/// 按做完的下级（提示词已回复、子任务完成，见 `ChildMark`）占的比例填（画法见 `TaskRingView`）。全做完时不画：
/// 行尾的"完成"已经说了这件事，满格的条只像一道下划线。进度的数字只写在元信息那一行（`TaskCopy.counts`），读屏也照它念。
nonisolated enum TaskRing: Equatable, Sendable {
    case plain
    case progress(done: Int, total: Int)

    init(_ marks: [ChildMark]?) {
        let done = marks?.filter(\.isDone).count ?? 0
        guard let marks, !marks.isEmpty, done < marks.count else { self = .plain; return }
        self = .progress(done: done, total: marks.count)
    }
}
