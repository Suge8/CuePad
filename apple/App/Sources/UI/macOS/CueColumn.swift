#if os(macOS)
import CueStore
import SwiftUI

/// 右边的 Cue（宽 400，`WideMetrics.cue`）：栏头在窗口最顶那一排（`CueTitle`），下面是 Cue 页（`CuePage`），对话到栏头下沿淡出（`fadesUnderHead`）。
/// 收起与放不下时也一直挂着（`MainWindow` 只是藏起它）：`shown` 为假时这一页不在前台（暂停订阅与实时状态、不算在看 Cue，`pageActive`）。
struct CueColumn: View {
    let shown: Bool

    var body: some View {
        CatalogGate {
            VStack(spacing: 0) {
                CueTitle()
                CuePage().fadesUnderHead()
            }
        }
        .environment(\.pageActive, shown)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Cue 的栏头（右边 Cue 那一栏顶上，手机与 iPad 是 `CueHeader`）：头像、名字、数字账一行（`CueLedger`，同手机名牌的第二行），最右一颗收起右栏的圆钮。
/// 点头像那一块从它下面长出 Cue 的面板（`CueNowPanel`，三端同一份：大脑、刚记下的、定时、技能与规则、在哪台 Mac 上运行与开关），记忆与定时从面板里去。
/// 收起右栏（同主菜单"显示 › 右栏"、⌃⌘I）把 Cue 收成右上一颗钮（`CueButton`），收没收起是用户的选择（`Workspace.hideCue`）。
/// 输入框里有没说出去的话时头像露"在听"。大脑那一排要的（`observingCueBrain`）随栏头一直订阅着：面板开时才建，长出的第一帧就是真的。
struct CueTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var panel = BubbleSwitch()
    @State private var brain: AgentModelChoice?

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 0) {
            Button { panel.toggle() } label: {
                HStack(spacing: 8) {
                    CueAvatar(cue.beat, size: .row).relaySpot(cue: .header)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            .bubble(isPresented: $panel.open, width: Self.panelWidth) { CueNowPanel(brain: brain, close: { panel.open = false }) }
            Spacer(minLength: Spacing.toolbarGap)
            Button("收起右栏", icon: .rightColumn) { workspace.hideCue() }
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(kind: .circular))
                .help("收起右栏（⌃⌘I）")
        }
        .padding(.horizontal, Spacing.page)
        .frame(height: Chrome.band)
        .windowDragArea()
        .observingCueBrain(into: $brain)
    }

    /// 面板同这一栏里的内容一样宽（栏宽减两侧栏边）。
    private static let panelWidth = WideMetrics.cue - 2 * Spacing.page
}

#endif
