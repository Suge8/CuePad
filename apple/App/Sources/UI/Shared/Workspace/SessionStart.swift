import CueStore
import Foundation

struct SessionStart: Identifiable {
    let id = UUID()
    var project: UUID?
    /// 已经发出的那一次：同一任务重开表单时从库中恢复，接着看进度并确认重复风险。
    var launched: SessionLaunch?
    var draft: ComposerDraft?
    var card: UUID?
    var name: String?
    /// 默认由哪台 Mac 开（`CueStore.handOffPlan` 定下的）；nil 是按项目的第一处绑定。
    var host: String?

    var launchKey: SessionLaunching.Key { card.map { .card($0) } ?? .form }

    func place(among places: [ProjectFolders.LaunchPlace]) -> ProjectFolders.LaunchPlace? {
        project.flatMap { project in
            let own = places.filter { $0.project.id == project }
            return own.first { host != nil && $0.host == host } ?? own.first
        } ?? places.first
    }
}
