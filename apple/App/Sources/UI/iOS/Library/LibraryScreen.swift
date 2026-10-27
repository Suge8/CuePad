#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的技能与规则（Cue 名牌的面板那一行推入，`Route.library`；底部那一排让开，`Dock.stays`）：看的是 Cue 运行那台 Mac 报上来的快照（`Workspace.library`）。
/// 两段（`LibraryDeck`）在页顶中间那块玻璃里换（`LibraryPanes`），它也是页名，不另写标题；
/// 右边一颗问号，点开是说明的气泡（`LibraryHelp`，贴在底部的纸：哪台 Mac、多久前报的也在里面）。
/// 一台 Mac 都还没报过时只写一句先去 Mac 上打开 CuePad。
struct LibraryScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var helpOpen = false

    var body: some View {
        Group {
            if let library = workspace.library {
                LibraryDeck(library: library)
            } else {
                Text("在 Mac 上打开 CuePad，它会把那台的技能与规则报过来")
                    .font(.subheadline).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // 同手机的任务气泡，贴在底部的纸：问号在系统导航栏里，栏里的项量不出能对上页面的框，气泡也盖不过导航栏
        .panel(isPresented: $helpOpen, style: .bubble(.bottom)) {
            if let library = workspace.library { LibraryHelp(library: library) }
        }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("技能与规则", center: { LibraryPanes().padding(Self.inset).headerPiece() }) {
            Button("说明", icon: .help) { helpOpen.toggle() }
                .disabled(workspace.library == nil)
        }
    }

    private static let inset: CGFloat = 3
}
#endif
