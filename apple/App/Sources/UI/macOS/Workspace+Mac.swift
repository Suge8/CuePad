#if os(macOS)
import AppKit
import CueStore
import Foundation

/// Mac 怎么摆去处（`Workspace+Navigation`）：内容区一次一页，卡片的编辑页盖在当前页上。
extension Workspace.Layout {
    static let native = Self.pages
}

extension Workspace {
    /// 打开 App 先到上次打开的项目（`AppSettings.currentProject`；失效的由 `reconcileCurrentProject` 退回），没有是 `Route.first`。
    static func openingRoute(_ services: AppServices) -> Route {
        services.settings.currentProject.map(Route.project) ?? .first
    }

    /// 换页时顺带的事：开着的编辑页收起、批量选择结束，记下去过的页（`MacPages`）；去会话页撤掉它那一组通知（点通知进来的也走这里），
    /// 去项目页记下它（下次打开回到它）。
    func willSelect(_ route: Route, root next: Route) {
        overlay = nil
        presses.clearSelection()
        presses.dismiss()
        pages.visit(from: root, to: next)
        if case .session(let session) = next, let alerts = services.alerts { Task { await alerts.dismiss(session: session.id) } }
        if case .project(let id) = next { services.settings.currentProject = id }
    }

    /// 灵感的编辑页整页盖在当前页上（`EditorLayer`）。
    func showEditor(_ card: UUID) {
        presses.clearSelection()
        overlay = .card(card)
    }

    /// 技能与说明里的一样（说明的编辑页、比一比）盖在当前页上（`LibraryItemLayer`），同灵感的编辑页。
    func openLibrary(_ item: LibraryItem) {
        presses.clearSelection()
        overlay = .library(item)
    }

    /// 格式不对的技能：用默认的编辑器打开它的 SKILL.md，自己改（改好了重扫就不在要整理里了）。
    func openSkillFile(_ directory: String) {
        NSWorkspace.shared.open(URL(filePath: directory).appending(path: "SKILL.md"))
    }

    /// 技能那一行：在访达里显示它的目录。
    func revealSkill(_ directory: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)])
    }

    /// 会话页按 Pi 的会话 id 认（桥上的在线会话）：只有记录 id 的入口（通知）从记录里取；记录已经没了（会话删了）就不去。
    func sessionRoute(_ id: UUID, sessionID: String?) -> Route? {
        if let sessionID { return .session(id, sessionID: sessionID) }
        do {
            let found = try services.store.snapshot { try $0.piSessionPage(PiSessionQuery(id: id)).items.first?.state.sessionID }.value
            return found.map { .session(id, sessionID: $0) }
        } catch {
            fail(error)
            return nil
        }
    }
}
#endif
