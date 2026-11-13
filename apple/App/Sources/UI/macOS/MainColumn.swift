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
            .overlay(alignment: .bottom) { CaptureSlot().padding(.trailing, under) }
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
            WideColumnHead().padding(inset).frame(height: Chrome.band).windowDragArea()
        }
    }
}

struct BesideColumn: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if let route = workspace.besideSession, let id = route.sessionID { SessionPage(route, column: .beside).id(id) }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

extension EnvironmentValues {
    @Entry var topBand: CGFloat = 0
}
#endif
