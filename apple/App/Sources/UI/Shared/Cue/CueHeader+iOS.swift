#if os(iOS)
import SwiftUI

struct CueHeader: View {
    var staged = false
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
            if !staged {
                plate(style).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: staged)
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
