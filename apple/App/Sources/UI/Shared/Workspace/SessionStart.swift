import CueStore
import Foundation

/// 打开时带的（`Workspace.newSession`）：`project` 是先选中的项目（Agent 页筛着的）。
struct SessionStart: Identifiable {
    let id = UUID()
    var project: UUID?
    /// 已经发出的那一次：同一任务重开表单时从库中恢复，接着看进度并确认重复风险。
    var launched: SessionLaunch?
    /// 从"发给 Agent"选了新会话：任务的正文与补的话带过来作开场。
    var draft: ComposerDraft?
    /// 为哪件任务开的（发给 Agent 时定下）：开好后关联它。
    var card: UUID?
    /// 显示的目标名：为任务开的是它的标题（`CueStore.handOffPlan`，与会话名同一条规则）；nil 时以项目名称呼。
    var name: String?
    /// 默认由哪台 Mac 开（`CueStore.handOffPlan` 定下的）；nil 是按项目的第一处绑定。
    var host: String?

    /// 默认在哪开：先选中的项目（有 `host` 时是它在那台 Mac 上的绑定），没有就是第一处。
    func place(among places: [ProjectFolders.LaunchPlace]) -> ProjectFolders.LaunchPlace? {
        project.flatMap { project in
            let own = places.filter { $0.project.id == project }
            return own.first { host != nil && $0.host == host } ?? own.first
        } ?? places.first
    }

}
