import SwiftUI

extension View {
    /// 项目页滚过封面以后，栏头那一排正中一颗回到顶部，写着还有几件没做完（Mac 与 iPad 宽屏；手机窄屏的页头另排）。
    func compactFocus(open: Int, shown: Bool, position: Binding<ScrollPosition>) -> some View {
        modifier(CompactFocusSlot(open: open, shown: shown, position: position))
    }
}

private struct CompactFocusSlot: ViewModifier {
    let open: Int
    let shown: Bool
    @Binding var position: ScrollPosition
    @State private var collapsed = false
    @Environment(\.headInset) private var inset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapseOffset: CGFloat = 140

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in
                withAnimation(Motion.fade) { collapsed = isCollapsed }
            }
            .overlay(alignment: .top) {
                if collapsed, shown {
                    CompactFocus(open: open) {
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { position.scrollTo(edge: .top) }
                    }
                    .frame(height: Chrome.band)
                    .padding(.top, inset.top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                }
            }
    }
}

private struct CompactFocus: View {
    let open: Int
    let scrollToTop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: scrollToTop) {
            HStack(spacing: Spacing.item) {
                Image(.above)
                if open > 0 {
                    Label { Text(open, format: .number) } icon: { Image(.task) }
                        .foregroundStyle(palette.ink2)
                }
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .glass))
        .help("回到顶部")
        .accessibilityLabel("回到顶部")
        .accessibilityValue(open > 0 ? Text("\(open) 个任务没做完") : Text(verbatim: ""))
    }
}
