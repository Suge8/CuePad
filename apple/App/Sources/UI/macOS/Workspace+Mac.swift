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
        overlay = .card(card)
    }

    func openLibrary(_ file: LibraryFile) {
        presses.clearSelection()
        overlay = .library(file)
    }

    func revealSkill(_ directory: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)])
    }

    /// 只有记录 id 的入口（通知）从记录里取；记录已经没了（会话删了）就不去。
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
