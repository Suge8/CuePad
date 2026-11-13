#if os(macOS)
import CueStore
import SwiftUI

/// 收起时也一直挂着（`CueDock` 只是藏起它），`pageActive` 为假时暂停订阅与实时状态、不算在看 Cue。
/// 它嵌在自己的托管视图里（`WideColumnHost`）：在窗口的托管视图里时 Cue 页的滚动区伸到标题栏底下，系统在那一截盖上滚动边缘效果、栏头看不见（`ColumnHostingView`）。
struct CueColumn: View {
    let fits: Bool
    /// 铺满着：栏头左边让出会话条藏起时的开合钮（`lead`），没有收起右栏那颗（换去处靠会话条）。
    let home: Bool
    let lead: CGFloat

    /// 右边那一栏时是浮在主区上的一块写字玻璃（同看板列头）：看板放不下的列滑到它下面，不在桌面上切断；内容往里收一圈。
    /// 铺满与抽屉不是：铺满时它就是页，抽屉有自己的面（`DrawerSurface`）。玻璃画在块里，收起、放回时随块平移（`WideColumnSlide`）。
    private var floats: Bool { fits && !home }

    var body: some View {
        VStack(spacing: 0) {
            CueTitle(fits: fits, home: home, lead: lead, inset: floats ? Self.float : 0)
            CuePage(grounded: !floats).fadesUnderHead()
        }
        .glass(in: .rect(cornerRadius: Radius.sheet), ink: .ground(shown: floats))
        .padding(floats ? Self.float : 0)
        .ignoresSafeArea(.container, edges: .top)
    }

    static let float = Spacing.item
}

/// 大脑那一排要的（`observingCueBrain`）随栏头一直订阅着：面板开时才建，长出的第一帧就是真的。
struct CueTitle: View {
    let fits: Bool
    let home: Bool
    let lead: CGFloat
    var inset: CGFloat = 0
    @Environment(Workspace.self) private var workspace
    @State private var panel = BubbleSwitch()
    @State private var brain: AgentModelChoice?

    var body: some View {
        HStack(spacing: 0) {
            Button { panel.toggle() } label: { CuePlate(card: false, style: .column).frame(width: Self.plateWidth - 2 * inset) }
                .buttonStyle(PressStyle(.button))
                // 悬停的淡底随名牌的胶囊（按钮的悬停底按框取圆角，这么宽的一块取的是 `Radius.card`）；玻璃垫在外面，它的边光与影子不被裁
                .clipShape(.capsule)
                .glass(in: .capsule)
                .help("换模型，看它刚记下的，去记忆、定时与设置")
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(panel.open ? "收起" : "换模型，看它刚记下的，去记忆与设置")
                .bubble(isPresented: $panel.open, width: .fixed(Self.panelWidth - 2 * inset)) { CueNowPanel(brain: brain, close: { panel.open = false }) }
            if home {
                Spacer(minLength: 0)
            } else {
                Button("收起右栏", icon: .rightColumn) { workspace.hideCue(fits: fits) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .icon))
                    .padding(.leading, Spacing.item)
                    .help("收起右栏（⌃⌘I）")
            }
        }
        .padding(.leading, home ? lead : Spacing.page)
        .padding(.trailing, Spacing.page)
        .frame(height: Chrome.band)
        .windowDragArea()
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel { panel.toggle() }
    }

    private static let panelWidth = WideMetrics.cue - 2 * Spacing.page
    /// 名牌铺满收起钮左边（Mac 的按钮按标签的理想宽排，不把给的宽传下去，所以给定宽）：数字账整排放得下。
    private static let plateWidth = panelWidth - ControlMetrics.height - Spacing.item
}

#endif
