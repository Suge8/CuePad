import SwiftUI

/// 沉浸式的栏（iOS 的状态栏与顶栏、回复框；Mac 的窗口工具栏与页面顶上那一排）与页面内容之间的规矩，只在这里写：
/// 栏的玻璃（返回钮、标题胶囊、圆钮，Cue 页头与搜索框那一排，Mac 页面顶上那一排 `pageHeader`）直接浮在内容上、钉在顶上，内容一直滚到它们后面、从按钮之间透出来——
/// 栏后面、栏下面不加任何遮罩、渐变、模糊或底色，系统的滚动边缘效果也关掉（`RouteView`），玻璃本身就是唯一的遮挡。
/// 否决过：顶栏后面的整条淡出（为了返回钮与页头之间的窄缝不露半截字）把内容遮住了。
/// 窗口最顶上那一条例外（iOS 的状态栏、Mac 红绿灯与工具栏圆钮那一条）：内容照样透到最顶，只在那一条垫一层页底色的渐变（`TopFade`，
/// iOS 在 `RouteView`、Mac 在主窗口的详情区，各一处，各页不写），上半截实，往下淡完——状态栏的字、红绿灯是系统画的、没有玻璃可垫，
/// 不垫就和内容叠成一团。否决过：整条裁掉只留页底色，灵动岛下面那一截空着像被遮住。页里浮着的东西都摆在这一条下面，不被它盖到。
/// 内容离栏多远靠内容边距（`contentGap`）：推入页由 `RouteView` 一处让出（上安全区再加这么多），自带顶上一排的页（Cue、搜索、Mac 的 `pageHeader`）让到那一排下面，各页不另写。
enum Bars {
    static let contentGap: CGFloat = 12
}

/// 窗口最顶上那一条的页底色渐变（`Bars`）：上半截实、到那一条下沿淡完，没有一条看得见的边。不接点按、读屏跳过。
struct TopFade: View {
    let color: Color
    private static let stops: [(alpha: Double, at: CGFloat)] = [(1, 0), (1, 0.55), (0.75, 0.7), (0.35, 0.85), (0, 1)]

    var body: some View {
        LinearGradient(stops: Self.stops.map { .init(color: color.opacity($0.alpha), location: $0.at) }, startPoint: .top, endPoint: .bottom)
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
