import SwiftUI

/// 页面内容与沉浸式栏之间的距离，只在这里定义：推入页由 `RouteView` 一处让出（上安全区再加这么多），自带顶上一排的页（Cue、搜索）让到那一排下面。
/// 各页不再自己写离顶栏多远。
enum Bars {
    static let contentGap: CGFloat = 12
}

#if os(iOS)
extension View {
    /// 沉浸式页面的内容只在状态栏的时间与图标那一段淡出（`statusBarBottom`）；Mac 没有状态栏，内容一直滚到窗口上沿，什么也不遮。
    /// 只是内容的透明度遮罩（mask），不往栏后面画任何颜色。遮罩只随页面在屏幕上的位置变（不读滚动位置），静止时不重算也不重画。
    /// 挂在整页上（右边那一栏的页由 `RouteView` 一处挂上；iPad 的 Cue 面板自己挂）：页面不碰屏幕上沿时什么也不遮。
    /// 用户定的规矩：顶栏（返回钮、标题胶囊、圆钮，Cue 页头与搜索框那一排）直接浮在内容上，栏下面的内容一直完整可见——
    /// 栏后面与栏下面不加任何遮罩、渐变、模糊或底色，玻璃本身就是唯一的遮挡，离栏多远靠内容边距（`Bars.contentGap`）。
    /// 返回钮与页头之间那道窄缝里露出半截字也照样露着：曾为它让 Cue 页与搜索页在整个顶栏后面淡掉，把栏下的内容遮住了，已撤掉，不要再加回来。
    func fadesUnderBars() -> some View { modifier(BarFade()) }

    /// 窗口根视图上量出状态栏的下沿，交给里面各页的 `fadesUnderBars`。
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

private struct BarFade: ViewModifier {
    /// 时间与图标在状态栏的上七成里（灵动岛下沿也在其中），那里全透、状态栏的字才读得清；之下一小截淡回。
    private static let clearPart: CGFloat = 0.7
    @Environment(\.statusBarBottom) private var statusBar

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                // 遮罩铺满整页（含安全区）：页面上沿压在状态栏上的那一段淡出，再往下内容一直清楚可见
                let top = proxy.frame(in: .global).minY - proxy.safeAreaInsets.top
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .clear, location: Self.clearPart), .init(color: .black, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: max(0, statusBar - top))
                    Rectangle()
                }
                .ignoresSafeArea()
            }
        }
    }
}
#endif
