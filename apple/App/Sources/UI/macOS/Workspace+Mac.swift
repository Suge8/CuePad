#if os(macOS)
import AppKit
import CueStore
import Foundation

extension Workspace {
    func showEditor(_ card: UUID) { present(.card(card)) }

    func openLibrary(_ file: LibraryFile) { present(.library(file)) }

    func revealSkill(_ directory: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)])
    }

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
