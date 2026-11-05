#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的技能与规则（Cue 名牌的面板那一行推入，`Route.library`）：看的是 Cue 运行那台 Mac 报上来的快照（`Workspace.library`）。
/// 两段（`LibraryDeck`）在页顶中间那块玻璃里换（`LibraryPanes`，同 Mac 主栏栏头），它也是页名，不另写标题；
/// 右边一颗问号，点开是说明的气泡（`LibraryHelp`，哪台 Mac、多久前报的也在里面），从问号长出（导航栏里的项，`BarHelpButton`）。
/// 一台 Mac 都还没报过时只写一句先去 Mac 上打开 CuePad。
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
