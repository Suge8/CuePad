#if os(macOS)
import CueStore
import SwiftUI

/// 宽屏一块里的内容（`PageLayer`、`SessionLayer`、`CoverLayer` 摆它）。页不论是哪一页都是挂着逛过的页的那一叠（`PageStack`）：页被别的块换下去时只是藏起，回来不用重排。
struct RouteBody: View {
    let route: Route?
    let column: Workspace.Column
    @Environment(\.underCue) private var under

    var body: some View {
        switch route {
        case .session(let session)?:
            if session.sessionID != nil { SessionPage(session, column: column).padding(.trailing, under) }
        case .libraryFile(let file)?:
            LibraryFilePage(file: file).underHead(Chrome.band)
        default:
            PageStack().overlay(alignment: .bottom) { SelectionSlot().padding(.trailing, under) }
        }
    }
}
#endif
