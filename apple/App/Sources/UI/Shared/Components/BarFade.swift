import SwiftUI

extension View {
    /// 沉浸式页面的内容只在屏幕最上那一条淡出：iOS 是状态栏的时间与图标那一段（`statusBarBottom`），Mac 是窗口工具栏下沿的一小段。
    /// 其余都不遮：顶栏、搜索那一排、底部栏与回复框的玻璃浮在清楚的内容上，玻璃本身就是唯一的遮挡；内容离栏多远靠内容边距（`Bars.contentGap`），不靠遮罩。
    /// 只是内容的透明度遮罩（mask），不往栏后面画任何颜色。遮罩只随页面在屏幕上的位置变（不读滚动位置），静止时不重算也不重画。
    /// 挂在整页上（iOS 推入页与标签根页由 `RouteView` 一处挂上；浮窗里的页自己挂）：页面不碰屏幕上沿时什么也不遮。
    func fadesUnderBars() -> some View { modifier(BarFade()) }
}

/// 页面内容与沉浸式栏之间的距离，只在这里定义：推入页由 `RouteView` 一处让出（上安全区再加这么多），标签根页让到顶上那一排下面。
/// 各页不再自己写离顶栏多远。
enum Bars {
    static let contentGap: CGFloat = 12
}

#if os(iOS)
extension EnvironmentValues {
    /// 屏幕上状态栏的下沿（全局坐标）：窗口的根视图（还没有导航栏，上安全区就是状态栏）量出来往下传。
    @Entry var statusBarBottom: CGFloat = 0
}

extension View {
    /// 窗口根视图上量出状态栏的下沿，交给里面各页的 `fadesUnderBars`。
    func measuresStatusBar() -> some View { modifier(StatusBarReader()) }
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

private struct BarFade: ViewModifier {
    #if os(iOS)
    @Environment(\.statusBarBottom) private var statusBar
    #else
    /// Mac：栏下沿往上多少开始淡回，比工具栏圆钮下沿到栏下沿的空隙短，圆钮后面一点影子都不留。
    private static let macEdge: CGFloat = 6
    #endif

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let (band, start) = band(proxy)
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .clear, location: start), .init(color: .black, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: band)
                    Rectangle()
                }
                .ignoresSafeArea()
            }
        }
    }

    /// 上面淡多高、从这段的几成处开始淡回（之上全透）。
    private func band(_ proxy: GeometryProxy) -> (height: CGFloat, start: CGFloat) {
        #if os(iOS)
        // 遮罩铺满整页（含安全区）：页面上沿压在状态栏上的那一段。时间与图标在这段的上七成里（灵动岛下沿也在其中），
        // 那里全透、状态栏的字才读得清；之下一小截淡回，再往下内容一直清楚可见
        let height = max(0, statusBar - (proxy.frame(in: .global).minY - proxy.safeAreaInsets.top))
        return (height, 0.7)
        #else
        let height = proxy.safeAreaInsets.top
        return (height, height > 0 ? max(0, (height - Self.macEdge) / height) : 0)
        #endif
    }
}
