#if os(iOS)
import CueStore
import SwiftUI

struct ProgressScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.underCue) private var under
    @Environment(\.headInset) private var inset
    @State private var board: TaskBoard?

    var body: some View {
        page.observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    @ViewBuilder private var page: some View {
        if workspace.layout == .wide {
            boardView
                .padding(.leading, WideMetrics.boardLead(inset))
                .padding(.trailing, under > 0 ? 0 : inset.trailing - BoardCardMetrics.inset)
                .padding(.top, -BoardCardMetrics.inset)
                // 最顶那一排就是玻璃列头，系统在状态栏下垫的那层雾会把它们盖淡
                .scrollEdgeEffectHidden(true, for: .top)
                .navigationTitle(Text("进展"))
        } else {
            boardView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .floatingHeader("进展")
        }
    }

    private var boardView: some View {
        let scope = workspace.scopedProject
        let shown = (board ?? .empty).only(scope)
        return Group {
            if verticalSizeClass == .compact || sizeClass == .regular {
                BoardColumns(board: shown, margin: workspace.layout == .wide ? 0 : 12, tail: under)
            } else {
                PhoneBoard(board: shown)
            }
        }
        .transaction(value: scope) { $0.disablesAnimations = true }
    }
}
#endif
