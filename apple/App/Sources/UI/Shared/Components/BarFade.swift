import SwiftUI

extension View {
    /// 沉浸式顶栏下的内容淡出：内容滚进上安全区（iOS 是状态栏加顶栏或标签根页顶上那一排，Mac 是窗口工具栏那一条）时，
    /// 按位置降低它自己的不透明度，在状态栏里淡到全透、到顶栏下沿回到全不透明。只是内容的透明度遮罩（mask），
    /// 不往栏后面画任何颜色：栏后没有内容的地方就是页面底色本身，玻璃仍是唯一的遮挡。
    /// 遮罩只随安全区变（不读滚动位置），静止时不重算也不重画；滚动时由渲染服务合成。
    /// 挂在滚动的那一层上：iOS 推入页由 `RouteView` 一处挂在整页上；标签根页的顶上那一排（`SearchRow`）是页里的
    /// `safeAreaBar`，整页的遮罩管不到它下面，所以根页另挂在自己的滚动区上（滚动区的上安全区含那一排）。
    func fadesUnderBars() -> some View { modifier(BarFade()) }
}

extension EnvironmentValues {
    /// 状态栏的高（iOS 窗口根部的上安全区，导航栏之外）；Mac 没有状态栏，为 0。
    @Entry var statusBarHeight: CGFloat = 0
}

private struct BarFade: ViewModifier {
    @Environment(\.statusBarHeight) private var statusBar

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let band = proxy.safeAreaInsets.top
                VStack(spacing: 0) {
                    LinearGradient(stops: Self.stops(band: band, statusBar: min(statusBar, band)), startPoint: .top, endPoint: .bottom)
                        .frame(height: band)
                    Rectangle()
                }
                .ignoresSafeArea()
            }
        }
    }

    /// 从屏幕顶往下：状态栏里全透（时间与电量下面没有字），过了状态栏下沿一小段还很淡，在顶栏的下半截才回到全不透明——
    /// 圆钮与标题胶囊后面只剩一层淡影，再经玻璃糊开，读不出背后的字。
    private static func stops(band: CGFloat, statusBar: CGFloat) -> [Gradient.Stop] {
        guard band > 0 else { return [.init(color: .black, location: 0), .init(color: .black, location: 1)] }
        let bar = band - statusBar
        func at(_ y: CGFloat) -> CGFloat { min(max(y / band, 0), 1) }
        return [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0), location: at(statusBar)),
            .init(color: .black.opacity(0.06), location: at(statusBar + bar * 0.5)),
            .init(color: .black.opacity(0.25), location: at(statusBar + bar * 0.82)),
            .init(color: .black, location: 1),
        ]
    }
}
