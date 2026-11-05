#if os(iOS)
import SwiftUI

/// Cue 页页顶那一排的名牌（手机与 iPad 同一个，`floatingHeader` 摆它）：一块实底玻璃，定高，宽只看放在哪（`PlateStyle`）——
/// 窄屏铺满侧栏钮右边整行，iPad 右侧的 Cue 面板里定宽居中；左边头像占两行高（没有环，Cue 在动时右下一颗靛青的点，`CueAvatar`），
/// 右边上一行名字、下一行数字账（`CueStatusLine` 的 tally，`CueLedger`），左对齐。
/// Cue 页这一排只有它：这一页的焦点就是 Cue，不放搜索钮；不随字长短变宽：数字账随时在变，跟着变宽整颗名牌就一直在动。
/// 比圆钮高一截（两行字要的高），对话按它让出（`floatingHeader` 的 `height`）。
/// 点它从顶部长出面板（`GrowPanel`，同一块玻璃长大）：名牌原地长成名片（头像从左边连续地长大、挪到正中，名字与数字账排在它下面、居中），下面是 Cue 自己的那几样
/// （`CueNowPanel`：大脑、上下文、记忆、设置），手机上这些只有这一个入口（额度在进展页顶栏的额度环里，在做的会话在会话条上）。
/// 头像只有一个、跟着长大（`PlateLayout`），接力的落点挂在它上面。名牌本身（`CuePlate`）与 Mac 右栏的栏头（`CueTitle`）是同一个。
/// 点名牌、点面板外、在名牌上往上划都收起；点面板里的一项先收起再去那里。
/// 开面板先收起键盘：面板盖住对话的上半截，键盘弹着时放不下；打开它就是从打字转去看 Cue，草稿留在输入框里，收起面板不再弹回（同推入别的页时交出焦点）。
/// 名牌浮在对话上，展开不改对话的布局，长大的只有这一块；展开与否只在这里（不进 `CueWatch`：别处也读它）。
/// 大脑那一行要的（设置与那台 Mac 的 Agent，`observingCueBrain`）随名牌一直订阅着：面板开时才建，长出的第一帧就是真的；其余都是整个窗口已经在订阅的。
struct CueHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.headerHost) private var host
    @Environment(Workspace.self) private var workspace
    @State private var expanded = DebugHooks.preset.cuePanelOpen
    @State private var brain: AgentModelChoice?

    /// 名牌的高：两行字（名字、数字账）上下各留一截。
    nonisolated static let height: CGFloat = 56

    var body: some View {
        let style = host == .page ? PlateStyle.fill : .compact
        ZStack(alignment: .topLeading) {
            // 窄屏：开侧栏的圆钮与名牌同一排、同一条中线；名牌长开时盖住它（点面板外先收起）
            if host == .page {
                Button("侧栏", icon: .sidebar) { workspace.toggleSidebar() }
                    .glassCircle()
                    .frame(height: Self.height)
                    .accessibilityIdentifier("narrow-sidebar")
                    // 长开时面板盖住它、读屏只读面板（模态，`GrowPanel`）
                    .readerHidden(expanded)
            }
            plate(style)
        }
    }

    private func plate(_ style: PlateStyle) -> some View {
        GrowPanel(open: $expanded, radius: Self.height / 2) {
            Button(action: toggle) { CuePlate(card: expanded, style: style) }
                .buttonStyle(.plain)
                .highPriorityGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    if expanded, drag.translation.height < -24 { toggle() }
                })
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "换模型，看它刚记下的，去记忆与设置")
        } panel: {
            CueNowPanel(brain: brain, close: toggle)
        }
        // 窄屏收着时让出左边的侧栏钮；长开时铺满整排、盖住它（`GrowPanel`）
        .padding(.leading, style.width == nil && !expanded ? FloatingHeaderLayout.slot : 0)
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel(toggle)
    }

    private func toggle() {
        if !expanded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        $expanded.grow(reduceMotion: reduceMotion)
    }
}
#endif
