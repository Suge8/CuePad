import Foundation

extension Workspace {
    /// 页面按哪个项目筛（进展页的两段）：项目范围（`projectScope`）里的项目进了回收站就是全部（nil）。
    var scopedProject: UUID? { catalog?.project(projectScope)?.id }
}
