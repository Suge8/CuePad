#if os(macOS)
import AppKit
import CueStore
import Foundation

extension Workspace {
    /// 平台呈现的副作用；去处由 Workspace+Wide 写入。
    func willSelect(_ route: Route, from previous: Route) {
        overlay = nil
        presses.clearSelection()
        presses.dismiss()
        pages.visit(from: previous, to: route)
    }

    /// 灵感的编辑页整页盖在当前页上（`EditorLayer`）。
    func showEditor(_ card: UUID) {
        presses.clearSelection()
        overlay = .card(card)
    }

    /// 技能与规则的文件页盖在当前页上（`LibraryFileLayer`），同灵感的编辑页；已开着一份时换成这一份（去重的几份之间切换）。
    func openLibrary(_ file: LibraryFile) {
        presses.clearSelection()
        overlay = .library(file)
    }

    /// 技能那一行的右键菜单：在访达里显示它的目录。
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
