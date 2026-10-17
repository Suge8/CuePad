import SwiftUI

/// 列表里一行的底：选中、按下、指针停着时铺在行后面的那一块，全 App 只有这一份——形状、颜色与过渡都在这里，
/// 调用处只说"这是一行"：按钮行挂 `RowStyle`（`.buttonStyle(.row)`），不是按钮的行（点按另有手势、行里还有别的按钮）挂 `.row()`。
///
/// 颜色：选中是选中底（`selection`），按下与指针停着是一层淡底（`fill`），选中盖过另两种。
///
/// 形状只有一条规则：同心圆角矩形（系统的 `ConcentricRectangle`），四角与最近的行容器（`rowContainer`）同心——
/// 挨着容器圆角的角是容器的圆角减去两者的间距，离容器角远的角取下限。容器只分两种：
/// - 浮着的行（默认：面板、侧栏、Mac 的列表）：底比行左右各宽出 `bleed`（行里的字仍与本栏的字对齐，底向两边让出一截），下限是 `radius`；
///   行与行之间隔着空的容器（手机 Cue 页头的面板）给出这段空（`gap`），底上下各伸进去一半，不贴着字；
/// - 铺满的行（`rowContainer(_:flush: true)`，手机的分组纸，同系统的分组列表）：底就是行的框，下限是直角——中间的行是直角，首尾两行的外角跟着纸。
///   行要贴到纸边：纸的首尾要多留白时放进首尾两行里，不给纸加内边距（不然底与纸边之间留一道缝，圆角也不同心）。
/// 底多大，能点的就多大。
///
/// 没声明容器的行按系统给的容器（窗口）算，落在下限。只在亮着时才建这块底：滚动时没亮的行不跟着算同心。
/// 行容器里铺方的底色要写形状（`.background(色, in: .rect)`）：iOS 26、macOS 26 起不写形状的底色按外层容器取同心圆角，
/// 拼在纸里的行之间会露出缺口。
/// 行底伸出了行的框：在滚动区里，滚动内容自己要给它留出边距（滚动区按自己的边裁）。
///
/// 按下：手机按下即亮、松开淡去（`Motion.quick`），不缩放——一屏几十行，缩放会让列表显得软；Mac 照原生列表，按下那一刻亮、松开即灭，没有过渡（同 `PressFeedback`）。
/// 悬停：iPad 的指针停在哪行哪行亮（同系统侧栏与列表；系统按钮自带的悬停效果关掉，不叠两层）；Mac 照访达、邮件，行默认不亮，
/// 只有本来就有悬停底的几种行（悬停才露出操作的：更早、回收站、任务行、任务浮窗的步骤）给 `hovers: true`。
/// 指针停没停在行上经环境（`rowHovered`）交给行里的内容，悬停才露出的操作读它，不再各自挂 `onHover`。
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
}

/// 按钮行（`RowMetrics` 的底）。
struct RowStyle: ButtonStyle {
    var selected = false
    var hovers = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(RowHighlight(selected: selected, pressed: configuration.isPressed, hovers: hovers))
    }
}

extension ButtonStyle where Self == RowStyle {
    static var row: RowStyle { RowStyle() }
}

extension View {
    /// 不是按钮的一行（`RowMetrics` 的底）：点按自己挂手势，行里另有按钮。
    func row(selected: Bool = false, hovers: Bool = false) -> some View {
        modifier(RowHighlight(selected: selected, pressed: false, hovers: hovers))
    }

    /// 一组行所在的容器：行底与它的形状同心。`flush`：行铺满容器的宽（手机的分组纸），否则行浮在容器里；
    /// `gap`：浮着的行之间隔着的空，底上下各伸进一半。
    func rowContainer(_ shape: some RoundedRectangularShape, flush: Bool = false, gap: CGFloat = 0) -> some View {
        containerShape(shape).environment(\.rowFit, RowFit(flush: flush, gap: gap))
    }
}

extension View {
    /// 一组行拼成的一张纸（手机书架的几组、Mac 的更早、资料与回收站）：纸是行容器，行铺满纸，里面的东西裁在纸的圆角里。
    func rowPaper(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape).rowContainer(shape, flush: true).paper(radius: radius)
    }
}

extension EnvironmentValues {
    /// 指针此刻停在所在的这一行上（行里悬停才露出的操作读它）。
    @Entry var rowHovered = false
    /// 调试预设：这一行一出现就画成指针停着的样子（`DebugHooks.hovers`，后台截图里指针进不来）。
    @Entry var rowHoverPreset = false
    @Entry fileprivate var rowFit = RowFit()
}

private struct RowFit {
    var flush = false
    var gap: CGFloat = 0

    /// 底比行的框向外伸出多少（取负就是收回来）。
    func bleed(_ sign: CGFloat = 1) -> EdgeInsets {
        guard !flush else { return EdgeInsets() }
        let side = RowMetrics.bleed * sign, edge = gap / 2 * sign
        return EdgeInsets(top: edge, leading: side, bottom: edge, trailing: side)
    }
}

private struct RowHighlight: ViewModifier {
    let selected: Bool
    let pressed: Bool
    let hovers: Bool
    @State private var hovering = false
    @Environment(\.rowFit) private var fit
    @Environment(\.rowHoverPreset) private var preset
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .environment(\.rowHovered, hovering)
            .padding(fit.bleed())
            .background { if let tint { shape.fill(tint).transition(.opacity) } }
            .contentShape(.rect)
            .modifier(Hover(tracks: tracksHover, hovering: $hovering))
            .padding(fit.bleed(-1))
            .onAppear { if preset { hovering = true } }
            .animation(Self.fade, value: selected)
            .animation(Motion.quick, value: hovering)
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
    private var tracksHover: Bool { true }
    /// 松开与选中的变化淡去（按下那一刻不带过渡）。
    private static let fade: Animation? = Motion.quick
    #else
    private var tracksHover: Bool { hovers }
    private static let fade: Animation? = nil
    #endif
}

/// 只在要悬停底的行上挂跟踪区：每个跟踪区滚动时都要跟着重算。
private struct Hover: ViewModifier {
    let tracks: Bool
    @Binding var hovering: Bool

    func body(content: Content) -> some View {
        if tracks {
            content.onHover { hovering = $0 }
                #if os(iOS)
                .hoverEffectDisabled()
                #endif
        } else {
            content
        }
    }
}
