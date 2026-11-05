#if os(macOS)
import CueStore
import SwiftUI

/// 右边的 Cue（宽 400，`WideMetrics.cue`）：栏头在窗口最顶那一排（`CueTitle`），下面是 Cue 页（`CuePage`），对话到栏头下沿淡出（`fadesUnderHead`）。
/// 收起时也一直挂着（`MainWindow` 只是藏起它，`pageActive` 为假时暂停订阅与实时状态、不算在看 Cue）；放不下时同一栏住在右缘的抽屉里（`fits` 为假）。
struct CueColumn: View {
    /// 在右边那一栏里（放得下）；假的是在抽屉里。
    let fits: Bool

    var body: some View {
        VStack(spacing: 0) {
            CueTitle(fits: fits)
            CuePage().fadesUnderHead()
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Cue 的栏头（右边 Cue 那一栏顶上，手机与 iPad 是 `CueHeader`）：头像、名字、数字账一行（`CueLedger`，同手机名牌的第二行），最右一颗收起右栏的圆钮。
/// 点头像那一块从它下面长出 Cue 的面板（`CueNowPanel`，三端同一份：大脑、刚记下的、定时、技能与规则、在哪台 Mac 上运行与开关），记忆与定时从面板里去。
/// 收起右栏（同主菜单"显示 › 右栏"、⌃⌘I）把 Cue 收成右上一颗钮（`CueButton`），收没收起是用户的选择；在抽屉里只关抽屉（`Workspace.hideCue`）。
/// 输入框里有没说出去的话时头像露"在听"。大脑那一排要的（`observingCueBrain`）随栏头一直订阅着：面板开时才建，长出的第一帧就是真的。
struct CueTitle: View {
    let fits: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var panel = BubbleSwitch()
    @State private var brain: AgentModelChoice?

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 0) {
            Button { panel.toggle() } label: {
                HStack(spacing: Spacing.item) {
                    CueAvatar(cue.beat, size: .row).relaySpot(cue: .header)
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                        Text(cue.name).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
                        CueStatusLine(tally: true, font: Typography.toolbarSubtitle).lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(.button))
            .help("换模型，看它刚记下的，去记忆、定时与设置")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(panel.open ? "收起" : "换模型，看它刚记下的，去记忆与设置")
            .animation(Motion.fade, value: cue.presence)
            .bubble(isPresented: $panel.open, width: .fixed(Self.panelWidth)) { CueNowPanel(brain: brain, close: { panel.open = false }) }
            Spacer(minLength: Spacing.item)
            Button("收起右栏", icon: .rightColumn) { workspace.hideCue(fits: fits) }
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(kind: .circular))
                .help("收起右栏（⌃⌘I）")
        }
        .padding(.horizontal, Spacing.page)
        .frame(height: Chrome.band)
        .windowDragArea()
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel { panel.toggle() }
    }

    /// 面板同这一栏里的内容一样宽（栏宽减两侧栏边）。
    private static let panelWidth = WideMetrics.cue - 2 * Spacing.page
}

#endif
