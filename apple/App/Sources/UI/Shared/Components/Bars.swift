import SwiftUI

/// 浮动玻璃与内容的边界：iOS 导航顶部使用系统滚动边缘效果，静态自绘页头由 `safeAreaBar` 提供真实下沿，
/// 推入页由系统导航栏提供。状态栏最顶一段仍由 `StatusBarBlur` 负责，不另造遮罩或滚动状态。
/// 宽屏 Cue 与会话栏继续用 `fadesUnderHead`：内容在文字栏头下淡进底色。
/// 对话底部的回复框仍浮在内容上；Mac 的托底由 `replyTray` 提供。完整约定见 docs/layout.md。
/// 首行距栏的留白只有 `contentGap`：系统导航页由 `RouteView` 给，自绘页头由 `FloatingHeader` 给。
enum Bars {
    static let contentGap: CGFloat = 12
    /// Mac 上文字栏头下沿那一截淡出的高（`fadesUnderHead`）。
    static let fade: CGFloat = 16
}

extension View {
    /// 宽屏那两栏（右边的 Cue、会话）：内容到栏头下沿淡进栏的底色（头注释的例外）。栏头让出的那一截（上安全区：iPad 的页顶那一排连同它下面的 `contentGap`）
    /// 铺满底色到那一排的下沿，从下沿起 `Bars.fade` 那一截淡出；Mac 两栏与 iPad 会话的栏头是页外的一排（没有上安全区），内容从它下沿开始，只剩淡出的那一截。
    /// 淡出从栏头下沿起、不收在它上面：iPad 的 Cue 名牌带投影，淡出收在名牌后面的话露出来的只剩最后几点，看着仍是一刀。
    /// Mac 的内容裁在栏头下沿；iPad 不裁：栏头与横条让出的都是安全区，按页的框裁就裁在名牌下沿与横条上沿，对话滚不进去、在那儿一刀切开。
    /// 滚动区自己伸进安全区、按它自己的框裁，越不出这一栏。
    /// 淡出是盖在内容上的一层底色、不接点按，不是遮罩：两栏的底都是桌面色（`palette.desk`），看起来一样，滚动时不用每帧离屏再合成一遍整栏。
    func fadesUnderHead(_ on: Bool = true) -> some View { modifier(HeadFade(on: on)) }
}

private struct HeadFade: ViewModifier {
    let on: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if on {
            content
                #if os(macOS)
                .clipped()
                #else
                // 这一栏已有栏头渐隐，不能再叠原生顶部边缘效果。
                .scrollEdgeEffectHidden(true, for: .top)
                #endif
                .overlay {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            palette.desk.frame(height: max(0, proxy.safeAreaInsets.top - Bars.contentGap))
                            LinearGradient(colors: [palette.desk, palette.desk.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: Bars.fade)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                    }
                    .allowsHitTesting(false)
                    .readerHidden(true)
                }
        } else {
            content
        }
    }
}

#if os(iOS)
/// 状态栏那一条的渐进模糊，整个窗口一份（`IOSRoot` 最外层），各页、推入转场与弹出的纸上都一样：顶上最糊，往下平滑减到不糊，不着色、不垫底，
/// 只盖上安全区那一条（状态栏的下沿就是页顶那一排的上沿），没有状态栏的窗口（横屏、台前调度的小窗）上安全区是 0，什么都不画。
/// 它就是系统在不在导航栏下的滚动视图顶上画的那一层（滚动边缘效果，渲染服务里一层变半径模糊），借一个空的、不滚、不接点按的滚动视图画出来：
/// 页里滚动视图自己的那一层在系统导航栏下会糊满整条栏；蒙着渐变的材质带底色，强度也不渐变，只是糊的那层淡出。
/// 边缘效果只在内容滚过边时画，所以空内容三倍高、停在中间那一段。
/// 开销全在渲染服务，主线程每帧没有活：会话列表每帧滚 40pt，主线程指令与掉帧同垫一层渐变一样（Release、模拟器）；真机 GPU 没量。
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
    /// 窗口根视图上量出状态栏的下沿，交给里面按它排的那一排（宽屏的提示横幅）。
    func measuresStatusBar() -> some View { modifier(StatusBarReader()) }
}

extension EnvironmentValues {
    /// 屏幕上状态栏的下沿（全局坐标）：窗口的根视图（还没有导航栏，上安全区就是状态栏）量出来往下传。
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
