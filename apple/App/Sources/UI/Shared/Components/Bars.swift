import SwiftUI

/// 沉浸式的栏（iOS 的状态栏与顶栏、回复框；Mac 的窗口工具栏）与页面内容之间的规矩，只在这里写：
/// 栏的玻璃（返回钮、标题胶囊、圆钮，Cue 页头与搜索框那一排）直接浮在内容上，内容一直滚到它们后面——
/// 栏后面、栏下面不加任何遮罩、渐变、模糊或底色，系统的滚动边缘效果也关掉（`RouteView`），玻璃本身就是唯一的遮挡。
/// 这是用户定的、提醒过多次：加过整条顶栏后面的淡出（为了返回钮与页头之间的窄缝不露半截字），把内容遮住了，已撤掉，不要再加回来。
/// iOS 的状态栏那一条例外：内容照样透到屏幕最顶，只在那一条垫一层页底色的渐变（`RouteView` 一处，各页不写），时间、电池那半截近乎实，往下淡完。
/// 状态栏的字是系统画的、没有玻璃可垫，不垫就和内容叠成一团；整条裁掉只留页底色也试过，灵动岛下面那一截空着像被遮住，用户撤回了。
/// Mac 的窗口上沿没有这一条，照旧滚到最顶。
/// 内容离栏多远靠内容边距（`contentGap`）：推入页由 `RouteView` 一处让出（上安全区再加这么多），自带顶上一排的页（Cue、搜索）让到那一排下面。
/// 各页不再自己写离顶栏多远。
enum Bars {
    static let contentGap: CGFloat = 12
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
