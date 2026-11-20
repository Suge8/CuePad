import SwiftUI

/// 并排的右半：第二个会话（`session` 给出它那一页），或左边那个会话的活预览。
/// 收起时这一块还要滑出去：里面的东西留到滑完再拆（`shown`），不先变成一块空底。
struct BesideColumn<Session: View>: View {
    @ViewBuilder let session: (SessionRoute) -> Session
    @Environment(Workspace.self) private var workspace
    @State private var shown: Shown?

    private struct Shown: Equatable {
        let beside: WideNavigation.Beside
        let owner: SessionRoute?
    }

    var body: some View {
        let now = workspace.beside.map { Shown(beside: $0, owner: workspace.session(in: .main)) }
        Group {
            switch (now ?? shown)?.beside {
            case .session(let route) where route.sessionID != nil: session(route)
            case .preview:
                if let owner = (now ?? shown)?.owner, let preview = workspace.livePreviews[owner.id] { LivePreviewPane(preview: preview) }
            default: EmptyView()
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: now) {
            guard now == nil else { return shown = now }
            guard (try? await Task.sleep(for: WideSlide.duration)) != nil else { return }
            shown = nil
        }
    }
}
