import SwiftUI

enum Bars {
    static let contentGap = Spacing.group
}

extension View {
    /// 盖在内容上的栏头让出的那一截：内容按它让位，滚上去时从栏头下沿起淡出，栏头四周与后面不留字。
    func underHead(_ height: CGFloat) -> some View {
        safeAreaPadding(.top, height).fades(.top, from: height)
    }

    /// 滚动内容在这一边淡出（`Chrome.fade` 长），`from` 是这一边先整段让掉多少。
    /// 是遮罩不是盖一层底色：Cue 页底下是天空，盖底色盖不住；也不用系统的滚动边缘效果：Mac 上嵌着的托管视图里不画，手机上只糊到名牌一半。
    func fades(_ edge: VerticalEdge, from inset: CGFloat = 0) -> some View {
        modifier(EdgeFade(edge: edge, inset: inset))
    }
}

private struct EdgeFade: ViewModifier {
    let edge: VerticalEdge
    let inset: CGFloat

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .scrollEdgeEffectHidden(true, for: edge == .top ? .top : .bottom)
            #endif
            .mask {
                GeometryReader { proxy in
                    let outer = edge == .top ? proxy.safeAreaInsets.top : proxy.safeAreaInsets.bottom
                    VStack(spacing: 0) {
                        Color.clear.frame(height: outer + inset)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Chrome.fade)
                        Color.black
                    }
                    .scaleEffect(y: edge == .top ? 1 : -1)
                    .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
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
