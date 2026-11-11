#if os(iOS)
import SwiftUI

/// 不随字长短变宽：数字账随时在变，跟着变宽整颗名牌就一直在动。
/// 头像只有一个、跟着长大（`PlateLayout`），接力的落点挂在它上面。名牌本身（`CuePlate`）与 Mac 右栏的栏头（`CueTitle`）是同一个。
/// 开面板先收起键盘：面板盖住对话的上半截，键盘弹着时放不下；打开它就是从打字转去看 Cue，草稿留在输入框里，收起面板不再弹回（同推入别的页时交出焦点）。
/// 名牌浮在对话上，展开不改对话的布局，长大的只有这一块；展开与否只在这里（不进 `CueWatch`：别处也读它）。
struct CueHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.headerHost) private var host
    @Environment(Workspace.self) private var workspace
    @State private var expanded = DebugHooks.preset.cuePanelOpen
    @State private var brain: AgentModelChoice?

    nonisolated static let height: CGFloat = 56

    var body: some View {
        let style = host == .page ? PlateStyle.fill : .compact
        ZStack(alignment: .top) {
            // 长开时面板盖住它们、读屏只读面板（模态，`GrowPanel`）：撤掉，不只是变透明——它们的玻璃与面板在同一个容器里由容器一起画，透明度管不到钮上的图标
            if !expanded {
                HStack {
                    if host == .page {
                        Button("侧栏", icon: .sidebar) { workspace.toggleSidebar() }
                            .accessibilityIdentifier("narrow-sidebar")
                    }
                    Spacer(minLength: 0)
                    RemoteMacButton()
                }
                .glassCircle()
                .frame(height: Self.height)
                .transition(.opacity)
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
        .padding(.horizontal, style.width == nil && !expanded ? FloatingHeaderLayout.slot : 0)
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel(toggle)
    }

    private func toggle() {
        if !expanded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        $expanded.grow(reduceMotion: reduceMotion)
    }
}
#endif
