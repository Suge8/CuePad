import SwiftUI

extension View {
    /// 纸面：从上沿极轻地亮到纸色的实底 + 上沿一线高光 + 1px 半透明描边；抬起的纸浅色下多一层柔影（深色只留描边）。
    /// `wash`：要你看的那张纸铺这种状态的淡底（`PiShown.wash`），代替纸色。
    func paper(cornerRadius: CGFloat = Radius.card, lifted: Bool = false, wash: Color? = nil) -> some View {
        modifier(PaperSurface(radius: cornerRadius, lifted: lifted, wash: wash))
    }

    /// 计数变化时数字滚动过去（增大往上滚、减小往下滚），不整块换字。
    func counting(_ value: Int) -> some View {
        contentTransition(.numericText(value: Double(value))).animation(Motion.nudge, value: value)
    }

    /// 控件层玻璃；"降低透明度"开启时退回实底。玻璃不叠玻璃：调用方不在玻璃里再套玻璃。
    /// `ink`：默认垫实底（写着字的玻璃）；只有图标的圆钮给 `.clear`（`GlassInk`）。
    func glass<S: Shape>(in shape: S, interactive: Bool = false, ink: GlassInk = .solid) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, ink: ink))
    }
}

/// 浮起的高度：投影只有这几档，Theme 以外不写 `.shadow(`（`lint.sh` 查）。新东西先问它浮得多高，不另配一组数。
/// 深色下平放的东西靠描边分层，抬起的纸不投影（`paper`）。
enum Elevation {
    /// 卡片角上的小圆钮。
    case hover
    /// 抬起的纸与提示横幅。
    case lifted
    /// 窗口内浮层与气泡：要从整窗里浮出来，比 `lifted` 重。
    case panel

    fileprivate var radius: CGFloat {
        switch self {
        case .hover: 6
        case .lifted: 10
        case .panel: 28
        }
    }

    fileprivate var offset: CGFloat {
        switch self {
        case .hover: 2
        case .lifted: 6
        case .panel: 10
        }
    }

    fileprivate func color(_ palette: Palette) -> Color { self == .panel ? palette.panelShadow : palette.shadow }
}

private struct ElevationShadow: ViewModifier {
    let level: Elevation?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.shadow(color: level?.color(palette) ?? .clear, radius: level?.radius ?? 0, y: level?.offset ?? 0)
    }
}

extension View {
    /// 投影；`nil` 不投（修饰符照挂，开关时视图的身份不变）。
    func elevation(_ level: Elevation?) -> some View { modifier(ElevationShadow(level: level)) }
}

/// 玻璃上的字要多好读。
enum GlassInk {
    case clear
    /// 写着字的（默认；顶栏标题、输入框、搜索框、提示横幅、状态行）：玻璃里垫一层页面底色（`Palette.inkWell`），边缘仍是玻璃的光。内容一直滚到这些玻璃后面，
    /// 背后什么都有可能（亮的截图、深的代码块）：只着色不垫底的话，深色下一张亮图就把玻璃衬成浅灰、米白的字只剩 1.7:1，
    /// 垫了底才在任何背景上都够 4.5:1（docs/ui.md）。
    case solid
}

private struct PaperSurface: ViewModifier {
    let radius: CGFloat
    let lifted: Bool
    let wash: Color?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .environment(\.rowSurface, wash ?? palette.paper)
            // 影子只挂在底那块形状上：挂在整块内容上时，里面的字、图与按钮要先离屏合成一遍再糊影子，转场与按压的每帧都重算。
            // 平放的纸只用描边：每张卡一个模糊阴影，侧栏开合时整面墙每帧都要重画这些阴影
            .background {
                Group { if let wash { shape.fill(wash) } else { shape.fill(palette.paperFill) } }
                    .elevation(lifted && !palette.dark ? .lifted : nil)
            }
            .overlay(shape.strokeBorder(palette.hair))
            // 上沿一线高光：纸边像被光擦过，与玻璃同一种光。只画上沿一条实色细线：渐变描边由 CPU 按整张卡的面积铺渐变，
            // 卡片一变宽（侧栏开合、拉窗口）整面墙每张都要重画，大库里开合侧栏的第一帧因此卡上百毫秒
            // 淡底上不画：白的一线在暖黄上像一道裂缝
            .overlay(alignment: .top) { if wash == nil { palette.sheen.frame(height: 1).padding(.horizontal, radius).padding(.top, 1) } }
    }
}

extension Palette {
    var paperFill: LinearGradient {
        LinearGradient(colors: [paperLit, paper], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let ink: GlassInk
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(palette.paper, in: shape)
                .overlay(shape.stroke(palette.hair))
        } else {
            switch ink {
            case .clear: content.glassEffect(glass, in: shape)
            case .solid: solid(content)
            }
        }
    }

    /// iOS 只在玻璃里垫一层 `inkWell`：背后的内容照样从玻璃里透出来（通透），字仍够 4.5:1。
    /// Mac 里外各垫一层九成实的：Mac 的玻璃会在它下面那层上再压暗、提亮一档，只垫在里面整块发灰；下面那层让浮在桌面上的（Cue 条、菜单栏面板）不透出壁纸的颜色。
    @ViewBuilder private func solid(_ content: Content) -> some View {
        #if os(iOS)
        content.background(palette.inkWell, in: shape).glassEffect(glass, in: shape)
        #else
        content.background(palette.solidGlass, in: shape).glassEffect(glass, in: shape).background(palette.solidGlass, in: shape)
        #endif
    }

    /// 全 App 自绘玻璃都是 `.regular`：内容一直滚到顶栏、回复框后面，玻璃是唯一的遮挡，栏后面不再垫模糊或渐变带。
    /// 否决了 `.clear`（加淡色 tint 也一样）：我们玻璃后面是文字，它几乎不糊开背后的字，栏上的标题、标签与问题卡和背后的字叠在一起读不出
    /// （系统规范也只把 clear 用在照片、视频这类背景上）；系统自己的返回钮与工具栏圆钮也是 regular，两种并排会不一致。
    private var glass: Glass {
        guard ink != .clear else { return .regular.interactive(interactive) }
        return .regular.tint(palette.glassTint).interactive(interactive)
    }
}

/// 按压反馈只有这几类（`PressStyle` 按种类、列表的行 `RowStyle`、系统的主按钮）。调用处只说按的是哪一种（`Press`），两端写法相同；
/// 每种在各平台长什么样只在 `PressFeedback` 定，行的底只在 `RowMetrics` 定。
/// 手机：按下快、松开带一点回弹，按种类缩到不同比例，按下有一下轻触感；行只亮底不缩放（一屏几十行，缩放会让列表显得软）；减弱动态效果时只降透明度。
/// Mac 照原生控件（访达、邮件、备忘录的按钮、列表与卡片都这样）：按下的那一刻变淡（卡片压暗一层），松开即复原，
/// 不缩放、不回弹、不震动——缩放与回弹是触屏的习惯，在指针下显得软、慢；触控板的震动在 macOS 只给对齐这类反馈，点按钮不震。
/// Mac 悬停：指针一进来就有回应（同 macOS 26 工具栏玻璃钮的悬停，与 Linear、Raycast、Arc），淡入淡出 `Motion.fade`、不挪位置不缩放：
/// 按钮在自己的框上浮一层淡底（`fill`，形状随框：方的、矮的是圆与胶囊，高的是圆角矩形），卡片整张亮一档（按下压暗的一半）。
/// 指针照 HIG 与访达、邮件：按钮、行、卡片都是箭头，手形只给打开网页的链接（`pointerStyle(.link)`）——手形在 Mac 上读作"这是网页链接"。
/// iPad 的指针用系统给按钮的悬停效果（自定义样式的按钮照样有），行另见 `RowStyle`。
enum Press {
    /// 圆钮、图标按钮。
    case button
    /// 标准按钮、胶囊。
    case control
    /// 整张卡片。
    case card
    /// 整宽的一条（虚线框的"写正文"）。
    case wide
    /// 字里行间的小钮（"显示更多"、折叠开合、行内的链与清掉）：标签就是那几个字或一个图标、不另画框。
    /// Mac 的悬停底向外宽出一圈（`HoverShape.inlineOutset`），不贴着字；手机按下只变淡、不缩放不震（同系统的 plain），一行字缩一下显得软。
    case inline
}

struct PressStyle: ButtonStyle {
    let kind: Press

    init(_ kind: Press = .control) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PressFeedback(pressed: configuration.isPressed, kind: kind))
    }
}

struct PressFeedback: ViewModifier {
    let pressed: Bool
    var kind = Press.control
    @Environment(\.isEnabled) private var isEnabled

    #if os(macOS)
    @Environment(\.palette) private var palette
    @State private var hovering = false
    /// 按钮按下时内容的透明度；卡片不变淡（整张变淡像停用），压暗一层，悬停时亮一半。
    private static let dimmed = 0.6
    private static let shade = 0.05

    /// 原生控件的高亮没有过渡：按下、松开都在那一帧到位，外层的动画（列表挪位、开合）也不带它；悬停的进出淡一下。
    /// 每种只挂自己要的那一个效果：亮度滤镜挂在每颗按钮上，按钮里的字都要另画一遍。
    func body(content: Content) -> some View {
        let active = pressed && isEnabled
        let lit = hovering && isEnabled
        Group {
            if kind == .card {
                content.brightness((active ? Self.shade : lit ? Self.shade / 2 : 0) * (palette.dark ? 1 : -1))
            } else {
                content
                    .overlay {
                        if lit {
                            HoverShape().fill(palette.fill).padding(kind == .inline ? HoverShape.inlineOutset : EdgeInsets())
                                .allowsHitTesting(false).transition(.opacity)
                        }
                    }
                    .opacity(active ? Self.dimmed : 1)
            }
        }
        .environment(\.buttonHovered, lit)
        .onHover { hovering = $0 }
        .presetHover($hovering)
        .animation(Motion.fade, value: lit)
        .animation(nil, value: active)
    }
    #else
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 各种类缩到多少：大面积只缩一点，不然文字发虚。
    private var scale: CGFloat {
        switch kind {
        case .button: 0.9
        case .control: 0.95
        case .card: 0.97
        case .wide: 0.98
        case .inline: 1
        }
    }

    func body(content: Content) -> some View {
        let active = pressed && isEnabled
        let card = kind == .card
        content
            .scaleEffect(active && !reduceMotion ? scale : 1)
            .brightness(active && card ? -0.02 : 0)
            .opacity(active && (reduceMotion || !card) ? (kind == .inline ? Self.inlineDimmed : 0.9) : 1)
            .animation(active ? Motion.press : Motion.release, value: active)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: active) { _, now in now && kind != .inline }
    }

    /// 字里行间的小钮按下时变淡到多少（同系统 plain 按钮）。
    private static let inlineDimmed = 0.5
    #endif
}

#if os(macOS)
extension EnvironmentValues {
    /// 指针此刻停在所在的这颗按钮上（`PressFeedback` 给标签里的内容）：悬停时要换颜色、露出记号的按钮读它，不各自再挂 `onHover`。
    @Entry var buttonHovered = false
}

extension View {
    /// 调试预设（`-CuePadHover`，`DebugHooks.Preset.hovered`）：这块盖住其中一点时画成指针停着的样子——后台截图里指针进不来；
    /// 按钮、行与卡的悬停都经它，平时什么都不挂。
    @ViewBuilder func presetHover(_ hovering: Binding<Bool>) -> some View {
        let points = DebugHooks.preset.hovered
        if !points.isEmpty {
            onGeometryChange(for: Bool.self) { frame in points.contains { frame.frame(in: .global).contains($0) } } action: { hovering.wrappedValue = $0 }
        } else {
            self
        }
    }
}

/// 按钮悬停那层淡底的形状：随按钮的框——方的是圆、矮的是胶囊（同圆钮与胶囊控件），高的是圆角不超过 `Radius.card` 的圆角矩形。
nonisolated private struct HoverShape: Shape {
    /// 字里行间的小钮（`Press.inline`）的悬停底比字宽出的一圈。
    static let inlineOutset = EdgeInsets(top: -2, leading: -6, bottom: -2, trailing: -6)

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(min(rect.width, rect.height) / 2, Radius.card), style: .continuous)
    }
}
#endif

/// 圆钮、胶囊与行尾动作的几何：可见尺寸按平台，iPhone 的命中高度始终至少 44。
enum ControlMetrics {
    #if os(iOS)
    static let height: CGFloat = 44
    static let compactHeight: CGFloat = 32
    #else
    static let height: CGFloat = 36
    static let compactHeight: CGFloat = 28
    #endif
    static let stroke: CGFloat = 1
    /// 停用的控件整体变淡到这么多，看得出点不了。
    static let disabledOpacity = 0.45
}

/// 控件只有一套外形与按压实现，空态、绑定引导和搜索栏共用；签名色只给主动作，其余是墨色。
/// 外形单拆成 `ControlSurface`：点开菜单的按钮（`MenuButton`）不是 `Button`，要同一个样子时直接挂它。
/// `glass`：浮在内容上的玻璃胶囊（Mac 工具栏与页顶那一排的项目范围、新任务、收起、清空回收站），与 `circular` 的玻璃圆钮同高；毁掉东西的（`role: .destructive`）字是出错色。
struct ControlButtonStyle: ButtonStyle {
    enum Kind { case primary, highlight, secondary, quiet, circular, glass }
    var kind = Kind.secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlSurface(kind: kind, compact: compact, destructive: configuration.role == .destructive))
            .modifier(PressFeedback(pressed: configuration.isPressed, kind: kind == .circular ? .button : .control))
    }
}

/// 控件的外形（`ControlButtonStyle` 的样子，不含按压）；停用时整体变淡，挂在菜单按钮上的同样。
struct ControlSurface: ViewModifier {
    var kind = ControlButtonStyle.Kind.secondary
    var compact = false
    var destructive = false
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        shape(content).opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
    }

    @ViewBuilder private func shape(_ content: Content) -> some View {
        switch kind {
        case .circular:
            content
                .font(Typography.body.weight(.medium))
                .foregroundStyle(ink)
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
                .glass(in: .circle, interactive: true, ink: .clear)
        case .glass:
            content
                .font(Typography.secondary.weight(.medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 14)
                .frame(height: ControlMetrics.height)
                .contentShape(.capsule)
                .glass(in: .capsule, interactive: true)
        default:
            content
                .font((compact ? Typography.meta : Typography.secondary).weight(.medium))
                .foregroundStyle(kind == .primary ? palette.onFill : kind == .highlight ? palette.signature : ink)
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.vertical, 6)
                .frame(minHeight: compact ? ControlMetrics.compactHeight : ControlMetrics.height)
                .background(background, in: .capsule)
                .overlay { Capsule().strokeBorder(kind == .secondary ? palette.hair : .clear, lineWidth: ControlMetrics.stroke) }
                #if os(iOS)
                .frame(minHeight: ControlMetrics.height)
                #endif
                .contentShape(.capsule)
        }
    }

    private var ink: Color { destructive ? palette.failure : palette.ink }

    private var background: Color {
        switch kind {
        case .primary: palette.signatureFill
        case .highlight: palette.selection
        case .quiet, .glass: .clear
        case .secondary, .circular: palette.fill
        }
    }
}
