import CueStore

/// 任务的完成圈怎么画（任务行、任务页、Mac 面板同一条规则）：没有步骤是只看状态的圆圈；有步骤、还没全做完时圈下多一条细的进度条，
/// 按做完的步骤占的比例填（画法见 `TaskRingView`）。全做完时不画：满格的条只像一道下划线。
/// 进度的数字只写在元信息那一行（`TaskCopy.progress`），读屏也照它念。
nonisolated enum TaskRing: Equatable, Sendable {
    case plain
    case progress(done: Int, total: Int)

    init(_ subtasks: TaskProgress?) {
        guard let subtasks, subtasks.done < subtasks.total else { self = .plain; return }
        self = .progress(done: subtasks.done, total: subtasks.total)
    }
}
