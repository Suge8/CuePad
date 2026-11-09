#if os(iOS)
import CueStore
import SwiftUI

struct LibraryScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let library = workspace.library {
                LibraryDeck(library: library)
            } else {
                Text("在 Mac 上打开 CuePad，它会把那台的技能与规则报过来")
                    .font(Typography.secondary).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.page + Spacing.inset).padding(.top, Spacing.vacant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("技能与规则", center: { LibraryPanes().padding(PaneMetrics.inset).headerPiece() }) {
            BarHelpButton {
                if let library = workspace.library { LibraryHelp(library: library) }
            }
            .disabled(workspace.library == nil)
        }
    }
}
#endif
