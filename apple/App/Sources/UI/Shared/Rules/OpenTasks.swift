import CueStore

extension CueStore {
    /// 没完成的任务（进行中在前，再是待办），各自按项目分组的顺序摊平；任务界面改用分组与三态之前的过渡读法。
    func openTasks() throws -> [CueTask] {
        try (tasks(.inProgress) + tasks(.todo)).flatMap(\.tasks)
    }
}
