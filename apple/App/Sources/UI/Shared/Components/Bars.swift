import SwiftUI

/// 沉浸式的栏（iOS 的状态栏与顶栏、回复框；Mac 的窗口工具栏与页面顶上那一排）与页面内容之间的规矩，只在这里写：
/// 栏的玻璃（页顶那一排 `floatingHeader` 的圆钮与中间那几块，页里钉住的分段与看板列头，Mac 会话页顶上那一排）直接浮在内容上、钉在顶上，
/// 内容一直滚到它们后面、从玻璃之间与玻璃里透出来——栏后面、栏下面不加任何遮罩、渐变、模糊或底色，滚动区也不从它们的下沿开始，
/// 系统的滚动边缘效果也关掉（`RouteView`），玻璃本身就是唯一的遮挡。
/// 否决过：顶栏后面的整条淡出（为了返回钮与页头之间的窄缝不露半截字）把内容遮住了。
/// 窗口最顶上那一条例外（iOS 的状态栏、Mac 红绿灯与工具栏圆钮那一条）：内容照样透到最顶，只在那一条垫一层页底色的渐变（`TopFade`，
/// iOS 在 `RouteView`、Mac 在主窗口的详情区，各一处，各页不写），上半截实，往下淡完——状态栏的字、红绿灯是系统画的、没有玻璃可垫，
/// 不垫就和内容叠成一团。iOS 上那一条只到灵动岛（刘海）的下沿（`statusStrip`），几乎全实、到下沿才淡完：时间与电量压在实底上，
/// 灵动岛下沿到安全区上沿那一截不垫，内容清楚透出来。否决过：整条裁掉只留页底色，灵动岛下面那一截空着像被遮住；
/// 渐变伸到安全区上沿、上半截才实，时间与电量下半截跟滚过去的字打架。页里浮着的东西都摆在这一条下面，不被它盖到。
/// 内容离栏多远靠内容边距（`contentGap`）：系统导航栏下的页由 `RouteView` 一处让出（上安全区再加这么多），自己画页顶那一排的页（窄屏的根、iPad 的 Cue 面板，`HeaderHost`；Mac 的会话页）让到那一排下面；Mac 其余页的控件在工具栏里，内容让到工具栏下面再隔这么多。
enum Bars {
    static let contentGap: CGFloat = 12

    #if os(iOS)
    /// 状态栏那一条垫多高：有灵动岛、刘海的屏（上安全区比无刘海的状态栏高得多）到它的下沿为止——系统不给它的框，
    /// 下沿比上安全区上沿高约 11pt（14 Pro 59/48、16 Pro 62/51）；没有的（带 Home 键的 iPhone、iPad）就是整条状态栏。
    static func statusStrip(below statusBar: CGFloat) -> CGFloat { statusBar > housedStatusBar ? statusBar - islandGap : statusBar }
    private static let housedStatusBar: CGFloat = 40
    private static let islandGap: CGFloat = 11
    #endif
}

/// 窗口最顶上那一条的页底色渐变（`Bars`）：`solid` 以上实、往下缓缓淡完到那一条下沿，没有一条看得见的边。不接点按、读屏跳过。
struct TopFade: View {
    let color: Color
    var solid: CGFloat = 0.55
    private static let fade: [Double] = [0.75, 0.35, 0]

    var body: some View {
        let step = (1 - solid) / CGFloat(Self.fade.count)
        let fading = Self.fade.enumerated().map { Gradient.Stop(color: color.opacity($1), location: solid + step * CGFloat($0 + 1)) }
        LinearGradient(stops: [.init(color: color, location: 0), .init(color: color, location: solid)] + fading, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if os(iOS)
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
