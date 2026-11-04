#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的技能与规则（Cue 名牌的面板那一行推入，`Route.library`）：看的是 Cue 运行那台 Mac 报上来的快照（`Workspace.library`）。
/// 两段（`LibraryDeck`）在页顶中间那块玻璃里换（`LibraryPanes`，同 Mac 主栏栏头），它也是页名，不另写标题；
/// 右边一颗问号，点开是说明的气泡（`LibraryHelp`，哪台 Mac、多久前报的也在里面），从问号长出（导航栏里的项，按读屏标识量它的框，`PanelHost.frame(of:)`）。
/// 一台 Mac 都还没报过时只写一句先去 Mac 上打开 CuePad。
struct LibraryScreen: View {
    private static let helpID = "library.help"
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(PanelHost.self) private var host
    @State private var helpOpen = false
    /// 问号此刻的框（窗口坐标，点下时量）：气泡从它长出
    @State private var help: CGRect?

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
        .panel(isPresented: $helpOpen, style: .bubble(help.map(BubbleSource.control) ?? .unanchored)) {
            if let library = workspace.library { LibraryHelp(library: library) }
        }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("技能与规则", center: { LibraryPanes().padding(PaneMetrics.inset).headerPiece() }) {
            Button("说明", icon: .help) {
                help = host.frame(of: Self.helpID)
                helpOpen.toggle()
            }
            .accessibilityIdentifier(Self.helpID)
            .disabled(workspace.library == nil)
        }
    }
}
#endif
