#if os(macOS)
import CueStore
import SwiftUI

/// 收起时也一直挂着（`CueDock` 只是藏起它），`pageActive` 为假时暂停订阅与实时状态、不算在看 Cue。
/// 它嵌在自己的托管视图里（`WideColumnHost`）：在窗口的托管视图里时 Cue 页的滚动区伸到标题栏底下，系统在那一截盖上滚动边缘效果、栏头看不见（`ColumnHostingView`）。
struct CueColumn: View {
    let fits: Bool

    var body: some View {
        CuePage()
            .safeAreaPadding(.top, CueTitle.band)
            .clipShape(.rect(cornerRadius: CuePanel.corner(fits: fits)))
            .overlay(alignment: .top) { CueTitle(fits: fits) }
            .cuePanel(fits: fits)
            .ignoresSafeArea(.container, edges: .top)
    }
}

struct CueTitle: View {
    let fits: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    @State private var open = DebugHooks.args.layoutOpts.cuePanel
    @State private var brain: AgentModelChoice?

    static let band: CGFloat = 64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PlateStyle.column.height / 2)
        VStack(spacing: 0) {
            Button { toggle() } label: {
                CuePlate(card: open, style: .column, reserve: open ? 0 : Self.fold, opens: open ? nil : false).frame(width: Self.width)
            }
            .buttonStyle(PressStyle(.button))
            .allowsHitTesting(!open)
            .help(open ? "" : "换模型，看它刚记下的，去记忆、定时与设置")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(open ? "收起" : "换模型，看它刚记下的，去记忆与设置")
            if open {
                CueNowPanel(brain: brain, close: { toggle(to: false) }).transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(shape)
        .glass(in: shape)
        .grownInPlace(isPresented: $open) { toggle(to: false) }
        .overlay(alignment: .topTrailing) {
            if !open {
                Button("收起右栏", icon: .rightColumn) { workspace.hideCue(fits: fits) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .icon))
                    .padding(.trailing, Spacing.item)
                    .frame(height: PlateStyle.column.height)
                    .help("收起右栏（⌃⌘I）")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.top, (Self.band - PlateStyle.column.height) / 2)
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
    private static let fold = ControlMetrics.height
}

#endif
