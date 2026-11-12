#if os(macOS)
import AppKit
import CueStore
import Foundation

extension Workspace {
    func willSelect(_ route: Route, from previous: Route) {
        overlay = nil
        presses.clearSelection()
        presses.dismiss()
        pages.visit(from: previous, to: route)
    }

    func showEditor(_ card: UUID) {
        presses.clearSelection()
        leaveHome()
        overlay = .card(card)
    }

    func openLibrary(_ file: LibraryFile) {
        presses.clearSelection()
        leaveHome()
        overlay = .library(file)
    }

    /// 盖在主区上的页（编辑、技能与规则的文件）要主区露着：Cue 铺满时先让到右边。
    private func leaveHome() {
        guard case .wide(var state) = navigation, state.home else { return }
        state.home = false
        navigation = .wide(state)
    }

    func revealSkill(_ directory: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)])
    }

    /// 只有记录 id 的入口（通知）从记录里取；记录已经没了（会话删了）就不去。
    func sessionRoute(_ id: UUID, sessionID: String?) -> Route? {
        if let sessionID { return .session(id, sessionID: sessionID) }
        do {
            let found = try services.store.snapshot { try $0.sessionPage(SessionQuery(id: id)).items.first?.state.sessionID }.value
            return found.map { .session(id, sessionID: $0) }
        } catch {
            fail(error)
            return nil
        }
    }
}
#endif
