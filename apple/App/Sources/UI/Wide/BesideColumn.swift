import SwiftUI

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
            case .session(let route) where route.sessionID != nil: session(route)
            case .preview:
                if let owner = (now ?? shown)?.owner, let preview = workspace.livePreviews[owner.id] { LivePreviewPane(preview: preview) }
            case .card(let id): card(id).id(id)
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
