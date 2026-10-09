import SwiftUI

extension View {
    /// 沉浸式栏下的内容淡出：内容滚进上安全区（iOS 是状态栏加顶栏或标签根页顶上那一排，Mac 是窗口工具栏那一条）时，
    /// 按位置降低它自己的不透明度：状态栏与圆钮、标题胶囊后面全透，只在栏的下沿最后一小段淡回全不透明。
    /// `bottom` 时下安全区（iPhone 底部栏所在的那一段）同样处理：玻璃的折射会把背后的字放大、扭曲着压在标签后面，
    /// 所以内容一进栏的上沿就淡掉，标签后面只剩页面底色。
    /// 只是内容的透明度遮罩（mask），不往栏后面画任何颜色：栏后没有内容的地方就是页面底色本身，玻璃仍是唯一的遮挡。
    /// 遮罩只随安全区变（不读滚动位置），静止时不重算也不重画；滚动时由渲染服务合成。
    /// 挂在滚动的那一层上：iOS 推入页由 `RouteView` 一处挂在整页上；标签根页的顶上那一排（`SearchRow`）是页里的
    /// `safeAreaBar`，整页的遮罩管不到它下面，所以根页另挂在自己的滚动区上（滚动区的上安全区含那一排）。
    /// `below`：淡回全不透明的那一段往栏下沿以下再伸多长（`Bars.contentGap`）：紧贴栏下沿滚过的那一行也淡着，
    /// 不和玻璃挤在一起、不在圆钮正下方像圆钮的标签。内容顶上要让出同样的高度，静止时第一行才不落在淡出段里。
    func fadesUnderBars(bottom: Bool = false, below: CGFloat = 0) -> some View { modifier(BarFade(bottom: bottom, below: below)) }
}

/// 页面内容与沉浸式栏之间的距离，只在这里定义：推入页由 `RouteView` 一处让出（上安全区再加这么多），
/// 标签根页让到顶上那一排下面；栏下的淡出伸到同样深（`fadesUnderBars(below:)`），静止时第一行全不透明、
/// 滚上去时贴着栏下沿的那一行已经淡了。各页不再自己写离顶栏多远。
enum Bars {
    static let contentGap: CGFloat = 12
}

private struct BarFade: ViewModifier {
    let bottom: Bool
    let below: CGFloat

    /// 栏下沿往上多少开始淡回：比圆钮下沿到栏下沿的空隙（标签根页那一排 8，推入页的导航栏约 10）短，圆钮与标题胶囊后面一点影子都不留。
    private static let edge: CGFloat = 6
    /// 底部栏上沿往里多深淡到全透：玻璃的边缘一段折射最强，背后的字在这段里就淡完。
    private static let bottomEdge: CGFloat = 18

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let top = proxy.safeAreaInsets.top, floor = bottom ? proxy.safeAreaInsets.bottom : 0
                VStack(spacing: 0) {
                    LinearGradient(stops: Self.topStops(band: top, below: below), startPoint: .top, endPoint: .bottom).frame(height: top + below)
                    Rectangle()
                    LinearGradient(stops: Self.bottomStops(band: floor), startPoint: .top, endPoint: .bottom).frame(height: floor)
                }
                .ignoresSafeArea()
            }
        }
    }

    /// 从屏幕顶往下：一直全透，到栏下沿前 `edge` 才起，先慢后快，到下沿以下 `below` 处全不透明。
    private static func topStops(band: CGFloat, below: CGFloat) -> [Gradient.Stop] {
        guard band > edge else { return [.init(color: .black, location: 0), .init(color: .black, location: 1)] }
        let height = band + below, start = (band - edge) / height
        return [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0), location: start),
            .init(color: .black.opacity(0.15), location: start + (1 - start) / 2),
            .init(color: .black, location: 1),
        ]
    }

    /// 从底部栏上沿往下：全不透明，`bottomEdge` 内淡到全透，往下一直全透。
    private static func bottomStops(band: CGFloat) -> [Gradient.Stop] {
        guard band > bottomEdge else { return [.init(color: .black, location: 0), .init(color: .black, location: 1)] }
        let end = bottomEdge / band
        return [
            .init(color: .black, location: 0),
            .init(color: .black.opacity(0.15), location: end / 2),
            .init(color: .black.opacity(0), location: end),
            .init(color: .black.opacity(0), location: 1),
        ]
    }
}
