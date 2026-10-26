import SwiftUI

/// 沉浸式的栏（iOS 的状态栏与顶栏、回复框；Mac 的窗口工具栏与页面顶上那一排）与页面内容之间的规矩，只在这里写：
/// 栏的玻璃（页顶那一排 `floatingHeader` 的圆钮与中间那几块，页里钉住的分段、看板列头与手机看板的行头，Mac 会话页顶上那一排）直接浮在内容上、钉在顶上，
/// 内容一直滚到它们后面、从玻璃之间与玻璃里透出来——栏后面、栏下面不加任何遮罩、渐变、模糊或底色，滚动区也不从它们的下沿开始，
/// 系统的滚动边缘效果也关掉（`RouteView`：系统导航栏下它糊满整条栏），玻璃本身就是唯一的遮挡。
/// 否决过：顶栏后面的整条淡出（为了返回钮与页头之间的窄缝不露半截字）把内容遮住了。
/// 窗口最顶上那一条：Mac（红绿灯与工具栏那一条）什么都不垫，内容透到窗口顶。iOS 的状态栏那一条是一层渐进模糊（`StatusBarBlur`）：
/// 时间与电量是系统画的、没有玻璃可垫，不糊就和滚过去的字叠成一团。否决过：垫页底色的渐变，底色看得出，淡完的那一处像一刀切开。
/// 内容离栏多远靠内容边距（`contentGap`）：系统导航栏下的页由 `RouteView` 一处让出（上安全区再加这么多），自己画页顶那一排的页（窄屏与 iPad 的根、iPad 的 Cue 面板，`HeaderHost`；Mac 的会话页）让到那一排下面；Mac 其余页的控件在工具栏里，内容让到工具栏下面再隔这么多。
enum Bars {
    static let contentGap: CGFloat = 12
}

#if os(iOS)
/// 状态栏那一条的渐进模糊，整个窗口一份（`IOSRoot` 最外层），各页、推入转场与弹出的纸上都一样：顶上最糊，往下平滑减到不糊，不着色、不垫底，
/// 只盖上安全区那一条（状态栏的下沿就是页顶那一排的上沿），没有状态栏的窗口（横屏、台前调度的小窗）上安全区是 0，什么都不画。
/// 它就是系统在不在导航栏下的滚动视图顶上画的那一层（滚动边缘效果，渲染服务里一层变半径模糊），借一个空的、不滚、不接点按的滚动视图画出来：
/// 页里滚动视图自己的那一层在系统导航栏下会糊满整条栏；蒙着渐变的材质带底色，强度也不渐变，只是糊的那层淡出。
/// 边缘效果只在内容滚过边时画，所以空内容三倍高、停在中间那一段。
/// 开销全在渲染服务，主线程每帧没有活：会话列表每帧滚 40pt，主线程指令与掉帧和原来垫渐变时一样（Release、模拟器）；真机 GPU 没量。
struct StatusBarBlur: View {
    var body: some View {
        Band().ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
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
