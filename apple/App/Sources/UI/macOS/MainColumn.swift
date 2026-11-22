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

    @ViewBuilder private var head: some View {
        if workspace.mainRoute == .progress, workspace.overlay == nil {
            WideColumnHead().padding(inset).frame(height: Chrome.band)
        } else {
            WideColumnHead().padding(inset).frame(height: Chrome.band)
                .overlay { if workspace.overlay != nil { OverlayTitle() } }
                .windowDragArea()
        }
    }
}

extension EnvironmentValues {
    @Entry var topBand: CGFloat = 0
}
#endif
