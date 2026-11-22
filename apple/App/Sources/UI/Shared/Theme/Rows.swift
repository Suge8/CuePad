import SwiftUI

/// 列表里一行的底：选中、按下、指针停着时铺在行后面的那一块，全 App 只有这一份——形状、颜色与过渡都在这里，
/// 调用处只说"这是一行"：按钮行挂 `RowStyle`（`.buttonStyle(.row)`），不是按钮的行（点按另有手势、行里还有别的按钮）挂 `.row()`。
///
/// 选中的行字是墨、半粗，由行自己按 `selected` 换字重（不着靛青）。
///
/// 形状只有一条规则：同心圆角矩形（系统的 `ConcentricRectangle`），四角与最近的行容器（`rowContainer`）同心。容器只分两种：
/// - 浮着的行（默认：面板、侧栏、Mac 的列表）：底比行左右各宽出 `bleed`（行里的字仍与本栏的字对齐，底向两边让出一截），下限是 `Radius.row`；
///   行在容器里至少让出 `bleed`，底才不越出容器；
/// - 铺满的行（`rowContainer(_:flush: true)`，手机的分组纸，同系统的分组列表）：底就是行的框，下限是直角——中间的行是直角，首尾两行的外角跟着纸。
///   行要贴到纸边：纸的首尾要多留白时放进首尾两行里，不给纸加内边距（不然底与纸边之间留一道缝，圆角也不同心）。
/// 只有图标的格与会话条上的行（`Chrome`：行首一格、收起时整行就是这一格）是第三种：底就是这一格见方的框，不向两边让出（`RowStyle(cell: true)`、`row(selected:cell:)`），
/// 四角同样与容器同心——行与格两种形状不混，图标钮不铺成横条。
///
/// 没声明容器的行按系统给的容器（窗口）算，落在下限。只在亮着时才建这块底：滚动时没亮的行不跟着算同心。
/// 行容器里铺方的底色要写形状（`.background(色, in: .rect)`）：iOS 26、macOS 26 起不写形状的底色按外层容器取同心圆角，
/// 拼在纸里的行之间会露出缺口。
/// 行底伸出了行的框：在滚动区里，滚动内容自己要给它留出边距（滚动区按自己的边裁）。
///
/// 按下：手机按下即亮、松开淡去（`Motion.fade`），不缩放——一屏几十行，缩放会让列表显得软；Mac 照原生列表，按下那一刻亮、松开即灭，没有过渡（同 `PressFeedback`）。
/// 悬停：iPad 系统按钮自带的悬停效果关掉，不叠两层；指针照系统仍是箭头（`PressFeedback`）。
/// 指针停没停在行上经环境（`rowHovered`）交给行里的内容；悬停才露出的操作只经 `hoverReveal`，不再各自挂 `onHover`、不插进行的排版。
///
/// 被否决的：各处自己画圆角矩形再配负边距（圆角对不上容器，曾有直角、7、8、9、10、12 六种）；容器 `clipShape` 裁角——浮着的行裁不出与容器的缝，
/// 只能管铺满的行；系统 `List` 的选中——Mac 上是灰胶囊、压不过墨色体系（见 `Sidebar`），手机上要整页换成 `List`。
nonisolated enum RowMetrics {
    #if os(iOS)
    static let height: CGFloat = 44
    static let bleed: CGFloat = 10
    #else
    static let height: CGFloat = 32
    static let bleed: CGFloat = 8
    #endif
    static let revealFade: CGFloat = 16
}

struct RowStyle: ButtonStyle {
    var selected = false
    var cell = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(RowHighlight(selected: selected, pressed: configuration.isPressed, cell: cell))
    }
}

extension ButtonStyle where Self == RowStyle {
    static var row: RowStyle { RowStyle() }
}

extension View {
    func row(selected: Bool = false) -> some View {
        modifier(RowHighlight(selected: selected, pressed: false, cell: false))
    }

    func rowPlate(@ViewBuilder _ plate: @escaping (ConcentricRectangle) -> some View) -> some View {
        modifier(RowPlate(plate: plate))
    }

    func hoverReveal(_ alignment: Alignment = .trailing, when shows: Bool = true, @ViewBuilder _ actions: () -> some View) -> some View {
        overlay(alignment: alignment) { HoverReveal(shows: shows, fills: alignment.vertical == .center, actions: actions()) }
    }

    func yieldsToReveal(when shows: Bool = true) -> some View { modifier(RevealYield(shows: shows)) }

    func rowContainer(_ shape: some RoundedRectangularShape, flush: Bool = false) -> some View {
        containerShape(shape).environment(\.rowFit, RowFit(flush: flush))
    }
}

extension View {
    func rowPaper(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return clipShape(shape).rowContainer(shape, flush: true).paper(cornerRadius: cornerRadius)
    }
}

extension EnvironmentValues {
    @Entry var rowHovered = false
    @Entry var rowPressed = false
    @Entry var rowSurface: Color?
    @Entry fileprivate var rowFit = RowFit()
}

private struct RevealYield: ViewModifier {
    let shows: Bool
    @Environment(\.rowHovered) private var hovered

    func body(content: Content) -> some View { content.opacity(shows && hovered ? 0 : 1) }
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
            actions
                .frame(maxHeight: fills ? .infinity : nil)
                .background {
                    ZStack { surface ?? palette.desk; palette.fill }
                        .compositingGroup()
                        .padding(.leading, -RowMetrics.revealFade)
                        .mask {
                            HStack(spacing: 0) {
                                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: RowMetrics.revealFade)
                                Color.black
                            }
                        }
                }
                .transition(.opacity)
        }
    }
}

private struct RowFit {
    var flush = false

    func bleed(_ sign: CGFloat = 1, cell: Bool = false) -> EdgeInsets {
        guard !flush, !cell else { return EdgeInsets() }
        let side = RowMetrics.bleed * sign
        return EdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
    }

    func shape(cell: Bool = false) -> ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(flush && !cell ? 0 : Radius.row)))
    }
}

private struct RowPlate<Plate: View>: ViewModifier {
    let plate: (ConcentricRectangle) -> Plate
    @Environment(\.rowFit) private var fit

    func body(content: Content) -> some View {
        content.padding(fit.bleed()).background { plate(fit.shape()) }.padding(fit.bleed(-1))
    }
}

private struct RowHighlight: ViewModifier {
    let selected: Bool
    let pressed: Bool
    let cell: Bool
    @State private var hovering = false
    @Environment(\.rowPressed) private var held
    @Environment(\.rowFit) private var fit
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .environment(\.rowHovered, hovering)
            .padding(fit.bleed(cell: cell))
            .background { if let tint { fit.shape(cell: cell).fill(tint).transition(.opacity) } }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            #if os(iOS)
            .hoverEffectDisabled()
            #else
            .presetHover($hovering)
            #endif
            .padding(fit.bleed(-1, cell: cell))
            .animation(Self.fade, value: selected)
            .animation(Motion.fade, value: hovering)
            .animation(pressed ? nil : Self.fade, value: pressed)
    }

    private var tint: Color? {
        if selected { return palette.selection }
        return isEnabled && (pressed || held || hovering) ? palette.fill : nil
    }

    #if os(iOS)
    private static let fade: Animation? = Motion.fade
    #else
    private static let fade: Animation? = nil
    #endif
}
