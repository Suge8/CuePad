#if os(macOS)
import CueStore
import SwiftUI

struct MainColumn: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under

    private var session: Bool { if case .session = workspace.mainRoute, workspace.overlay == nil { true } else { false } }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                PageStack()
                Group {
                    EditorLayer()
                    LibraryFileLayer()
                }
                .safeAreaPadding(.top, Chrome.band)
                .padding(.trailing, under)
                .zIndex(1)
            }
            .overlay(alignment: .bottom) { SelectionSlot().padding(.trailing, under) }
            if !session { head.padding(.trailing, under) }
        }
        .environment(\.topBand, Chrome.band)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// 进展页那一排是看板的列头：栏头只占两端那几颗钮（左端项目范围、右端要关注时的同步提醒），不盖住列头（空处拖窗口由看板自己接）。
    @ViewBuilder private var head: some View {
        if workspace.mainRoute == .progress, workspace.overlay == nil {
            WideColumnHead().padding(inset).frame(height: Chrome.band)
        } else {
            // 编辑页的标题叠在让出两边之后的整栏正中：下面的正文栏也是按整栏居中的，放进那一排里会被两头的钮挤偏
            WideColumnHead().padding(inset).frame(height: Chrome.band)
                .overlay { if workspace.overlay != nil { OverlayTitle() } }
                .windowDragArea()
        }
    }
}

/// 收起时这一块还要滑出去：里面的东西留到滑完再拆（`shown`），不先变成一块空底。
struct BesideColumn: View {
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
            case .session(let route) where route.sessionID != nil: SessionPage(route, column: .beside)
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

extension EnvironmentValues {
    @Entry var topBand: CGFloat = 0
}
#endif
