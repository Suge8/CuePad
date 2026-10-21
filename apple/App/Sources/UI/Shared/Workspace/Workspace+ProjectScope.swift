import Foundation

extension Workspace {
    /// 页面按哪个项目筛（任务页、会话页）：项目范围（`projectScope`）里的项目进了回收站就是全部（nil）。
    var scopedProject: UUID? { catalog?.project(projectScope)?.id }
}
