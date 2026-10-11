import SwiftUI

extension View {
    /// 沉浸式页面的内容只在屏幕最上、最下那一条淡出：iOS 是状态栏（灵动岛那一带）与主屏指示条（`ScreenBars`），
    /// Mac 是窗口工具栏那一条。顶栏、搜索那一排、底部栏与回复框的玻璃浮在清楚的内容上，玻璃本身就是唯一的遮挡；
    /// 内容离栏多远靠内容边距（`Bars.contentGap`），不靠遮罩。
    /// 只是内容的透明度遮罩（mask），不往栏后面画任何颜色。遮罩只随页面在屏幕上的位置变（不读滚动位置），静止时不重算也不重画。
    /// 挂在整页上（iOS 推入页与标签根页由 `RouteView` 一处挂上；浮窗里的页自己挂）：页面不碰屏幕上下沿时什么也不遮。
    func fadesUnderBars() -> some View { modifier(BarFade()) }
}

/// 页面内容与沉浸式栏之间的距离，只在这里定义：推入页由 `RouteView` 一处让出（上安全区再加这么多），标签根页让到顶上那一排下面。
/// 各页不再自己写离顶栏多远。
enum Bars {
    static let contentGap: CGFloat = 12
}

#if os(iOS)
/// 屏幕上状态栏的下沿与主屏指示条的上沿（全局坐标）：窗口的根视图（还没有导航栏，上下安全区就是这两条）量出来往下传。
nonisolated struct ScreenBars: Equatable, Sendable {
    var top: CGFloat = 0
    var bottom: CGFloat = .infinity
}

extension EnvironmentValues {
    @Entry var screenBars = ScreenBars()
}

extension View {
    /// 窗口根视图上量出状态栏与主屏指示条的位置，交给里面各页的 `fadesUnderBars`。
    func measuresScreenBars() -> some View { modifier(ScreenBarsReader()) }
}

private struct ScreenBarsReader: ViewModifier {
    @State private var bars = ScreenBars()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: ScreenBars.self) { proxy in
                let frame = proxy.frame(in: .global)
                return ScreenBars(top: frame.minY, bottom: frame.maxY)
            } action: { bars = $0 }
            .environment(\.screenBars, bars)
    }
}
#endif

private struct BarFade: ViewModifier {
    #if os(iOS)
    @Environment(\.screenBars) private var bars
    #else
    /// Mac：栏下沿往上多少开始淡回，比工具栏圆钮下沿到栏下沿的空隙短，圆钮后面一点影子都不留。
    private static let macEdge: CGFloat = 6
    #endif

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let (top, bottom, ramp) = bands(proxy)
                VStack(spacing: 0) {
                    LinearGradient(stops: Self.stops(band: top, ramp: ramp), startPoint: .top, endPoint: .bottom).frame(height: top)
                    Rectangle()
                    LinearGradient(stops: Self.stops(band: bottom, ramp: bottom), startPoint: .bottom, endPoint: .top).frame(height: bottom)
                }
                .ignoresSafeArea()
            }
        }
    }

    /// 上下各淡多高、上面那条在最后多长里淡回（iOS 状态栏的下半条，Mac 只在工具栏下沿那一小段）。
    private func bands(_ proxy: GeometryProxy) -> (top: CGFloat, bottom: CGFloat, ramp: CGFloat) {
        #if os(iOS)
        // 遮罩铺满整页（含安全区）：页面的上下沿压在状态栏、指示条上的那一段
        let frame = proxy.frame(in: .global)
        let top = max(0, bars.top - (frame.minY - proxy.safeAreaInsets.top))
        let bottom = max(0, frame.maxY + proxy.safeAreaInsets.bottom - bars.bottom)
        // 上面：灵动岛与时间那半条全透，下半条渐进淡回
        return (top, bottom, top / 2)
        #else
        let top = proxy.safeAreaInsets.top
        return (top, 0, min(Self.macEdge, top))
        #endif
    }

    /// 从屏幕边往里：全透，到离内沿 `ramp` 处起先慢后快，到内沿全不透明。
    private static func stops(band: CGFloat, ramp: CGFloat) -> [Gradient.Stop] {
        guard band > 0, ramp > 0 else { return [.init(color: .black, location: 0), .init(color: .black, location: 1)] }
        let start = (band - ramp) / band
        return [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0), location: start),
            .init(color: .black.opacity(0.15), location: start + (1 - start) / 2),
            .init(color: .black, location: 1),
        ]
    }
}
