import SwiftUI

enum Bars {
    static let contentGap = Spacing.group
}

extension View {
    /// 盖在内容上的栏头让出的那一截：内容按它让位，滚上去时滑到栏头的玻璃下面。
    func underHead(_ height: CGFloat) -> some View {
        safeAreaPadding(.top, height).underGlass()
    }

    /// 滚到浮着的玻璃下面的内容：玻璃是唯一的遮挡，不垫渐变，也关掉系统的滚动边缘效果（它只糊到名牌一半，名牌两侧的字仍清楚）。
    func underGlass() -> some View { scrollEdgeEffectHidden(true, for: .top) }

    /// 会话条下沿：底下是工具那一排、不是玻璃，淡出一截（`Chrome.fade` 长），不一刀切。
    func fadesAtBottom() -> some View {
        mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Chrome.fade)
            }
        }
    }
}

#if os(iOS)
/// 借一个空的、不滚的滚动视图画出系统滚动视图顶上那一层（滚动边缘效果，渲染服务里的变半径模糊）：
/// 页里滚动视图自己的那一层在系统导航栏下会糊满整条栏；蒙渐变的材质带底色，强度也不渐变。
/// 边缘效果只在内容滚过边时画，所以空内容三倍高、停在中间那一段。
/// 开销全在渲染服务，主线程每帧没有活（模拟器 Release 实测与垫一层渐变相当；真机 GPU 没量）。
struct StatusBarBlur: View {
    var body: some View {
        Band().ignoresSafeArea().allowsHitTesting(false).readerHidden(true)
    }

    private struct Band: UIViewRepresentable {
        func makeUIView(context: Context) -> UIScrollView { Scrolled() }
        func updateUIView(_ view: UIScrollView, context: Context) {}
    }

    private final class Scrolled: UIScrollView {
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            // 点状态栏回顶归页里的列表：两个滚动视图都答时谁都不滚
            scrollsToTop = false
            showsVerticalScrollIndicator = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = CGSize(width: bounds.width, height: bounds.height * 3)
            if contentSize != size { contentSize = size }
            if contentOffset.y != bounds.height { contentOffset.y = bounds.height }
        }
    }
}

extension View {
    func measuresStatusBar() -> some View { modifier(StatusBarReader()) }
}

extension EnvironmentValues {
    @Entry var statusBarBottom: CGFloat = 0
}

private struct StatusBarReader: ViewModifier {
    @State private var bottom: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottom = $0 }
            .environment(\.statusBarBottom, bottom)
    }
}
#endif
