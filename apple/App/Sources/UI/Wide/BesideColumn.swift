import SwiftUI

/// 主区并排时最左那块右边的第 `index` 块：别的会话（`session` 给出它那一页）、最左那个会话的活预览，或一条灵感（`card`）。
/// 收起时这一块还要滑出去：里面的东西留到滑完再拆（`shown`），不先变成一块空底。换了放的东西（插进来一块、两块对调）时旧的淡出、新的淡入。
struct BesideColumn<Session: View, Card: View>: View {
    let index: Int
    @ViewBuilder let session: (SessionRoute) -> Session
    @ViewBuilder let card: (UUID) -> Card
    @Environment(Workspace.self) private var workspace
    @State private var shown: Shown?

    private struct Shown: Equatable {
        let pane: WideNavigation.Beside
        let owner: SessionRoute?
    }

    var body: some View {
        let panes = workspace.beside
        let now = panes.indices.contains(index) ? Shown(pane: panes[index], owner: workspace.session(in: .main)) : nil
        ZStack {
            switch (now ?? shown)?.pane {
            case .session(let route) where route.sessionID != nil: session(route).transition(.opacity)
            case .preview:
                if let owner = (now ?? shown)?.owner, let preview = workspace.livePreviews[owner.id] { LivePreviewPane(preview: preview).transition(.opacity) }
            case .card(let id): card(id).id(id).transition(.opacity)
            default: EmptyView()
            }
        }
        .animation(Motion.fade, value: (now ?? shown)?.pane)
        .ignoresSafeArea(.container, edges: .top)
        .task(id: now) {
            guard now == nil else { return shown = now }
            guard (try? await Task.sleep(for: WideSlide.duration)) != nil else { return }
            shown = nil
        }
    }
}
