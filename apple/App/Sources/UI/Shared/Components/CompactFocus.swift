import SwiftUI

extension View {
    /// 项目页滚过封面以后，栏头里胶囊旁边一颗回到顶部，写着还有几件没做完（Mac 与 iPad 宽屏；手机窄屏的页头另排）。
    /// 页只交出这颗钮（`PageTop`），由栏头摆在胶囊后面：摆在栏头正中时长标题的胶囊会盖住它。
    func compactFocus(open: Int, shown: Bool, position: Binding<ScrollPosition>) -> some View {
        modifier(CompactFocusSlot(open: open, shown: shown, position: position))
    }
}

/// 宽屏一块里页交给栏头的回到顶部：页写、栏头读（`PageLayer` 建一份，两边共用）。
@Observable final class PageTop {
    var open: Int?
    @ObservationIgnored var scrollToTop: () -> Void = {}
}

private struct CompactFocusSlot: ViewModifier {
    let open: Int
    let shown: Bool
    @Binding var position: ScrollPosition
    @State private var collapsed = false
    @Environment(PageTop.self) private var top: PageTop?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapseOffset: CGFloat = 140

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > Self.collapseOffset } action: { _, isCollapsed in collapsed = isCollapsed }
            .onChange(of: collapsed && shown ? open : nil, initial: true) { _, offered in
                top?.scrollToTop = { [reduceMotion, $position] in
                    withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { $position.wrappedValue.scrollTo(edge: .top) }
                }
                withAnimation(Motion.fade) { top?.open = offered }
            }
            .onDisappear { top?.open = nil }
    }
}

/// 栏头里胶囊后面的那颗回到顶部（`WideColumnHead`）。
struct PageTopButton: View {
    @Environment(PageTop.self) private var top: PageTop?

    var body: some View {
        if let top, let open = top.open {
            CompactFocus(open: open, scrollToTop: top.scrollToTop).fixedSize().transition(.opacity)
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
