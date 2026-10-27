import SwiftUI

/// 列表里一行的底：选中、按下、指针停着时铺在行后面的那一块，全 App 只有这一份——形状、颜色与过渡都在这里，
/// 调用处只说"这是一行"：按钮行挂 `RowStyle`（`.buttonStyle(.row)`），不是按钮的行（点按另有手势、行里还有别的按钮）挂 `.row()`。
///
/// 颜色：选中是选中底（`selection`），按下与指针停着是一层淡底（`fill`），选中盖过另两种。
///
/// 形状只有一条规则：同心圆角矩形（系统的 `ConcentricRectangle`），四角与最近的行容器（`rowContainer`）同心——
/// 挨着容器圆角的角是容器的圆角减去两者的间距，离容器角远的角取下限。容器只分两种：
/// - 浮着的行（默认：面板、侧栏、Mac 的列表）：底比行左右各宽出 `bleed`（行里的字仍与本栏的字对齐，底向两边让出一截），下限是 `radius`；
/// - 铺满的行（`rowContainer(_:flush: true)`，手机的分组纸，同系统的分组列表）：底就是行的框，下限是直角——中间的行是直角，首尾两行的外角跟着纸。
///   行要贴到纸边：纸的首尾要多留白时放进首尾两行里，不给纸加内边距（不然底与纸边之间留一道缝，圆角也不同心）。
/// 底多大，能点的就多大。
///
/// 没声明容器的行按系统给的容器（窗口）算，落在下限。只在亮着时才建这块底：滚动时没亮的行不跟着算同心。
/// 行容器里铺方的底色要写形状（`.background(色, in: .rect)`）：iOS 26、macOS 26 起不写形状的底色按外层容器取同心圆角，
/// 拼在纸里的行之间会露出缺口。
/// 行底伸出了行的框：在滚动区里，滚动内容自己要给它留出边距（滚动区按自己的边裁）。
///
/// 按下：手机按下即亮、松开淡去（`Motion.fade`），不缩放——一屏几十行，缩放会让列表显得软；Mac 照原生列表，按下那一刻亮、松开即灭，没有过渡（同 `PressFeedback`）。
/// 悬停：指针停在哪行哪行亮（Mac 与 iPad 同一套，淡入淡出 `Motion.fade`；iPad 系统按钮自带的悬停效果关掉，不叠两层）——点得到的东西指针一过就有回应，
/// 同 Linear、Arc 的侧栏与列表；指针照系统仍是箭头（`PressFeedback`）。
/// 指针停没停在行上经环境（`rowHovered`）交给行里的内容；悬停才露出的操作只经 `hoverReveal`，不再各自挂 `onHover`、不插进行的排版。
///
/// 被否决的：各处自己画圆角矩形再配负边距（圆角对不上容器，曾有直角、7、8、9、10、12 六种）；容器 `clipShape` 裁角——浮着的行裁不出与容器的缝，
/// 只能管铺满的行；系统 `List` 的选中——Mac 上是灰胶囊、压不过墨色体系（见 `Sidebar`），手机上要整页换成 `List`。
enum RowMetrics {
    #if os(iOS)
    static let bleed: CGFloat = 10
    static let radius: CGFloat = 12
    #else
    static let bleed: CGFloat = 8
    static let radius: CGFloat = 8
    #endif
    /// 悬停露出的操作垫的实底靠字那一侧淡入的宽度（`hoverReveal`）。
    static let revealFade: CGFloat = 16
}

/// 按钮行（`RowMetrics` 的底）。
struct RowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(RowHighlight(selected: selected, pressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == RowStyle {
    static var row: RowStyle { RowStyle() }
}

extension View {
    /// 不是按钮的一行（`RowMetrics` 的底）：点按自己挂手势，行里另有按钮。
    func row(selected: Bool = false) -> some View {
        modifier(RowHighlight(selected: selected, pressed: false))
    }

    /// 指针停在这一行时才露出的操作（任务行的"开始"、"更早"与回收站的删除与恢复、记忆的钉住与忘掉）：浮在行上、不占排版——
    /// 露出与收起时行里的字一个都不挪、不换行、不让位。挂在行的内容上（`row()` 或 `RowStyle` 之内）：读的是这一行的 `rowHovered`。
    /// 操作垫一块与悬停的行同色的实底（行所在那层的底叠悬停的淡底，`Palette.hovered`），盖住压到的字；靠字那一侧淡入一截，不切断半个字。
    /// 竖直居中的（单行的行尾）实底铺满行高，像行本身；贴底的（多行的记忆）只垫操作那一条。`when` 为假时这一行没有要露的（悬停也不垫底）。
    /// 被否决的：露出时插进行里（任务行的"开始"挤窄标题、把时间挤掉，"更早"的删除挤掉摘要）；透明占位（不露时也占着行尾，窄列里标题白白少一截）。
    func hoverReveal(_ alignment: Alignment = .trailing, when shows: Bool = true, @ViewBuilder _ actions: () -> some View) -> some View {
        overlay(alignment: alignment) { HoverReveal(shows: shows, fills: alignment.vertical == .center, actions: actions()) }
    }

    /// 一组行所在的容器：行底与它的形状同心。`flush`：行铺满容器的宽（手机的分组纸），否则行浮在容器里。
    func rowContainer(_ shape: some RoundedRectangularShape, flush: Bool = false) -> some View {
        containerShape(shape).environment(\.rowFit, RowFit(flush: flush))
    }
}

extension View {
    /// 一组行拼成的一张纸（手机书架的几组、Mac 的更早、置顶与回收站）：纸是行容器，行铺满纸，里面的东西裁在纸的圆角里。
    func rowPaper(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape).rowContainer(shape, flush: true).paper(radius: radius)
    }
}

extension EnvironmentValues {
    /// 指针此刻停在所在的这一行上（行里悬停才露出的操作读它）。
    @Entry var rowHovered = false
    /// 行所在那一层的底色（悬停露出的操作垫的实底照它调，`hoverReveal`）：纸面（`paper()`）里是纸，别处是页面底。
    @Entry var rowSurface: Color?
    @Entry fileprivate var rowFit = RowFit()
}

private struct HoverReveal<Actions: View>: View {
    let shows: Bool
    let fills: Bool
    let actions: Actions
    @Environment(\.rowHovered) private var hovered
    @Environment(\.rowSurface) private var surface
    @Environment(\.palette) private var palette

    var body: some View {
        if shows, hovered {
            let plate = palette.hovered(surface ?? palette.desk)
            actions
                .frame(maxHeight: fills ? .infinity : nil)
                .background(plate)
                .background(alignment: .leading) {
                    LinearGradient(colors: [plate.opacity(0), plate], startPoint: .leading, endPoint: .trailing)
                        .frame(width: RowMetrics.revealFade).offset(x: -RowMetrics.revealFade)
                }
                .transition(.opacity)
        }
    }
}

private struct RowFit {
    var flush = false

    /// 底比行的框向外伸出多少（取负就是收回来）。
    func bleed(_ sign: CGFloat = 1) -> EdgeInsets {
        guard !flush else { return EdgeInsets() }
        let side = RowMetrics.bleed * sign
        return EdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
    }
}

private struct RowHighlight: ViewModifier {
    let selected: Bool
    let pressed: Bool
    @State private var hovering = false
    @Environment(\.rowFit) private var fit
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .environment(\.rowHovered, hovering)
            .padding(fit.bleed())
            .background { if let tint { shape.fill(tint).transition(.opacity) } }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #if os(iOS)
            .hoverEffectDisabled()
            #else
            .presetHover($hovering)
            #endif
            .padding(fit.bleed(-1))
            .animation(Self.fade, value: selected)
            .animation(Motion.fade, value: hovering)
            .animation(pressed ? nil : Self.fade, value: pressed)
    }

    private var tint: Color? {
        if selected { return palette.selection }
        return isEnabled && (pressed || hovering) ? palette.fill : nil
    }

    private var shape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(fit.flush ? 0 : RowMetrics.radius)))
    }

    #if os(iOS)
    /// 松开与选中的变化淡去（按下那一刻不带过渡）。
    private static let fade: Animation? = Motion.fade
    #else
    private static let fade: Animation? = nil
    #endif
}
