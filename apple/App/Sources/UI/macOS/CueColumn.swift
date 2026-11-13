#if os(macOS)
import CueStore
import SwiftUI

/// 收起时也一直挂着（`CueDock` 只是藏起它），`pageActive` 为假时暂停订阅与实时状态、不算在看 Cue。
/// 它嵌在自己的托管视图里（`WideColumnHost`）：在窗口的托管视图里时 Cue 页的滚动区伸到标题栏底下，系统在那一截盖上滚动边缘效果、栏头看不见（`ColumnHostingView`）。
struct CueColumn: View {
    let fits: Bool
    /// 铺满着：栏头两边让出会话条藏起时的开合钮（`lead`），没有收起右栏那颗（换去处靠会话条）。
    let home: Bool
    let lead: CGFloat

    var body: some View {
        // 对话从名牌底下穿过去、一直滚到窗口上缘（同手机）：名牌是浮在上面的一块玻璃，不裁、不盖淡出
        CuePage()
            .safeAreaPadding(.top, CueTitle.band)
            .overlay(alignment: .top) { CueTitle(fits: fits, home: home, lead: lead) }
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// 名牌在这一栏正中、与点开的面板同宽：面板从它正下方长出，两边对齐。右栏的收起钮在名牌里的右端，不另占一格。
/// 大脑那一排要的（`observingCueBrain`）随栏头一直订阅着：面板开时才建，长出的第一帧就是真的。
struct CueTitle: View {
    let fits: Bool
    let home: Bool
    let lead: CGFloat
    @Environment(Workspace.self) private var workspace
    @State private var panel = BubbleSwitch(open: DebugHooks.preset.cuePanelOpen)
    @State private var brain: AgentModelChoice?

    /// 比窗口最顶那一排（`Chrome.band`）高：名牌是这一栏的主角，头像与名字比旁边栏头的控件大一档。
    static let band: CGFloat = 64

    var body: some View {
        Button { panel.toggle() } label: {
            CuePlate(card: false, style: .column, reserve: home ? 0 : Self.fold).frame(width: Self.width)
        }
        .buttonStyle(PressStyle(.button))
        // 悬停的淡底随名牌的胶囊（按钮的悬停底按框取圆角，这么宽的一块取的是 `Radius.card`）；玻璃垫在外面，它的边光与影子不被裁
        .clipShape(.capsule)
        .glass(in: .capsule)
        .help("换模型，看它刚记下的，去记忆、定时与设置")
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(panel.open ? "收起" : "换模型，看它刚记下的，去记忆与设置")
        .bubble(isPresented: $panel.open, width: .fixed(Self.width)) { CueNowPanel(brain: brain, close: { panel.open = false }) }
        .overlay(alignment: .trailing) {
            if !home {
                Button("收起右栏", icon: .rightColumn) { workspace.hideCue(fits: fits) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .icon))
                    .padding(.trailing, Spacing.item)
                    .help("收起右栏（⌃⌘I）")
            }
        }
        .padding(.horizontal, home ? lead : Spacing.page)
        .frame(maxWidth: .infinity)
        .frame(height: Self.band)
        .windowDragArea()
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel { self.panel.toggle() }
    }

    /// Mac 的按钮按标签的理想宽排，不把给的宽传下去，所以给定宽：右栏里两边各留一道页边。
    private static let width = WideMetrics.cue - 2 * Spacing.page
    /// 名牌里右端那颗收起钮连同它左边一道缝，字不排到它底下。
    private static let fold = ControlMetrics.height
}

#endif
