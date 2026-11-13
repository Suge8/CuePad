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
        // 对话从名牌底下穿过去、一直滚到板的上缘（同手机）：名牌是浮在上面的一块玻璃，不盖淡出；对话按板的圆角裁，不从角上露出去
        CuePage(grounded: !fits)
            .safeAreaPadding(.top, CueTitle.band)
            .clipShape(.rect(cornerRadius: CuePanel.corner(fits: fits, home: home)))
            .overlay(alignment: .top) { CueTitle(fits: fits, home: home, lead: lead) }
            .cuePanel(fits: fits, home: home)
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// 名牌在这一栏正中，点它原地长成面板（同手机的 `CueHeader`）：头像长大居中、名字落到它下面（`CuePlate` 的 `card`），面板在名牌底下淡入，整块是同一块玻璃。
/// 长开时往下盖在对话上、不挤动它；点外面与 Esc 的关法走窗口浮层那一套（`grownInPlace`）。右栏的收起钮在名牌里的右端，长开时让开。
/// 大脑那一排要的（`observingCueBrain`）随栏头一直订阅着：面板开时才建，长出的第一帧就是真的。
struct CueTitle: View {
    let fits: Bool
    let home: Bool
    let lead: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    @State private var open = DebugHooks.preset.cuePanelOpen
    @State private var brain: AgentModelChoice?

    /// 比窗口最顶那一排（`Chrome.band`）高：名牌是这一栏的主角，头像与名字比旁边栏头的控件大一档。
    static let band: CGFloat = 64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PlateStyle.column.height / 2)
        VStack(spacing: 0) {
            Button { toggle() } label: {
                CuePlate(card: open, style: .column, reserve: home || open ? 0 : Self.fold, opens: open ? nil : false).frame(width: Self.width)
            }
            .buttonStyle(PressStyle(.button))
            // 长开后上半截不再是按钮（悬停亮起的是半张名片）：面板里的空白处点了都不收，收起只有点外面与 Esc
            .allowsHitTesting(!open)
            .help(open ? "" : "换模型，看它刚记下的，去记忆、定时与设置")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(open ? "收起" : "换模型，看它刚记下的，去记忆与设置")
            if open {
                CueNowPanel(brain: brain, close: { toggle(to: false) }).transition(.opacity)
            }
        }
        .frame(width: Self.width)
        // 高按内容取：外面那一排定高（`band`），照它给的高排的话面板里的字会被压小
        .fixedSize(horizontal: false, vertical: true)
        // 悬停的淡底随名牌的圆角（按钮的悬停底按框取圆角）；玻璃垫在外面，它的边光与影子不被裁
        .clipShape(shape)
        .glass(in: shape)
        .grownInPlace(isPresented: $open) { toggle(to: false) }
        .overlay(alignment: .topTrailing) {
            if !home, !open {
                Button("收起右栏", icon: .rightColumn) { workspace.hideCue(fits: fits) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .icon))
                    .padding(.trailing, Spacing.item)
                    .frame(height: PlateStyle.column.height)
                    .help("收起右栏（⌃⌘I）")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, home ? lead : Spacing.page)
        .padding(.top, (Self.band - PlateStyle.column.height) / 2)
        // 这一排定高，长开的那一截伸到它下面
        .frame(maxWidth: .infinity)
        .frame(height: Self.band, alignment: .top)
        .windowDragArea()
        .observingCueBrain(into: $brain)
        .onChange(of: active) { if !active { open = false } }
        .debugExposesCuePanel { toggle() }
    }

    private func toggle(to value: Bool? = nil) {
        let next = value ?? !open
        guard next != open else { return }
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { open = next }
    }

    /// Mac 的按钮按标签的理想宽排，不把给的宽传下去，所以给定宽：离板的两边与上沿同样一小圈（板里再留整道页边的话，右栏里第四项数字放不下）。
    private static let width = WideMetrics.cue - 2 * CuePanel.float - 2 * Spacing.item
    /// 名牌里右端那颗收起钮连同它左边一道缝，字不排到它底下。
    private static let fold = ControlMetrics.height
}

#endif
