import SwiftUI

extension View {
    /// 纸面：从上沿极轻地亮到纸色的实底 + 上沿一线高光 + 1px 半透明描边；抬起的纸浅色下多一层柔影（深色只留描边）。
    func paper(radius: CGFloat = 14, lifted: Bool = false) -> some View {
        modifier(PaperSurface(radius: radius, lifted: lifted))
    }

    /// 计数变化时数字滚动过去（增大往上滚、减小往下滚），不整块换字。
    func counting(_ value: Int) -> some View {
        contentTransition(.numericText(value: Double(value))).animation(Motion.snappy, value: value)
    }

    /// 控件层玻璃；"降低透明度"开启时退回实底。玻璃不叠玻璃：调用方不在玻璃里再套玻璃。
    /// `ink`：玻璃上写着要读的字时着色调高几档（`GlassInk`）。
    func glass<S: Shape>(in shape: S, interactive: Bool = false, ink: GlassInk = .clear) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, ink: ink))
    }
}

/// 玻璃上的字要多好读：玻璃仍是唯一的遮挡，只是着色调高，不在玻璃外面垫任何东西。
enum GlassInk {
    /// 圆钮、标签栏这类只有图标与短标签的玻璃。
    case clear
    /// 写着要读的字（顶栏标题、输入框）：深色下压一层暗色调，背后的亮字糊开后不再和上面的次要字同亮；浅色下垫一层淡纸色，
    /// 背后的行糊成的灰块不再像污渍落在字周围。外沿照样通透。
    case legible
    /// 浮在一整片字上、自己也写着一行或一页字（提示横幅、Mac 底部输入栏、任务面板）：玻璃里再垫九成实的页面底色，
    /// 背后的字透不过来，边缘仍是玻璃的光。
    case solid
}

private struct PaperSurface: ViewModifier {
    let radius: CGFloat
    let lifted: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(palette.paperFill, in: shape)
            .overlay(shape.strokeBorder(palette.paperEdge(lifted: lifted)))
            // 上沿一线高光：纸边像被光擦过，与玻璃同一种光。只画上沿一条实色细线：渐变描边由 CPU 按整张卡的面积铺渐变，
            // 卡片一变宽（侧栏开合、拉窗口）整面墙每张都要重画，大库里开合侧栏的第一帧因此卡上百毫秒
            .overlay(alignment: .top) { palette.sheen.frame(height: 1).padding(.horizontal, radius).padding(.top, 1) }
            // 平放的纸只用描边：每张卡一个模糊阴影，侧栏开合时整面墙每帧都要重画这些阴影
            .shadow(color: .black.opacity(palette.dark || !lifted ? 0 : 0.08), radius: lifted ? 10 : 0, y: lifted ? 6 : 0)
    }
}

extension Palette {
    /// 纸面的底：从上沿极轻地亮到纸色。纸上要盖住一块再淡开时（Mac 任务纸展开的新行）用同一份，盖的那块与纸分不出来。
    var paperFill: LinearGradient {
        LinearGradient(colors: [paperLit, paper], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
    }

    /// 纸面的描边色。
    func paperEdge(lifted: Bool = false) -> Color { dark ? Color.white.opacity(lifted ? 0.14 : 0.07) : hair }
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
        } else if ink == .solid {
            content.background(palette.desk.opacity(0.9), in: shape).glassEffect(glass, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    /// 全 App 自绘玻璃都是 `.regular`：内容一直滚到顶栏、底部栏、回复框后面，玻璃是唯一的遮挡，栏后面不再垫模糊或渐变带。
    /// 否决了 `.clear`（加淡色 tint 也一样）：我们玻璃后面是文字，它几乎不糊开背后的字，栏上的标题、标签与问题卡和背后的字叠在一起读不出
    /// （系统规范也只把 clear 用在照片、视频这类背景上）；系统自己的返回钮与工具栏圆钮也是 regular，两种并排会不一致。
    private var glass: Glass {
        // 深色的暗色调让标题下那行次要字对背后糊开的字够 4.5:1，又不至于成一块黑斑
        guard ink != .clear else { return .regular.interactive(interactive) }
        return .regular.tint(palette.dark ? .black.opacity(0.4) : palette.paper.opacity(0.45)).interactive(interactive)
    }
}

/// 动效：没有大幅的空间过渡（Mac 打开卡片是编辑页原地淡入）；位置与尺寸只在列表、面板里小幅挪动，其余为短淡入淡出。减弱动态效果时一律直接到终态或只淡入淡出。
/// 动效 token（Mac 与 iOS 共用）：位置与尺寸用不回弹的临界阻尼弹簧，都在 300ms 以内；弹簧从当前呈现值继续，天然可打断。
/// 只有按压松开带一点回弹（`pressUp`），给手感；常驻的循环动效只给 Agent 在工作与话在路上（`PiStateDot`）和进行中的流光，都在 `LoopLayer`（Core Animation），离屏即停。
enum Motion {
    /// 短动效：列表里挪位置、面板、浮层、切换。
    static let snappy = Animation.spring(duration: 0.25, bounce: 0)
    /// 卡片在墙上挪位（同列下移、新卡入场）：定长 0.24s，弹簧的尾巴会让实际时长超过 300ms。
    static let move = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
    static let panel = snappy
    /// 颜色、透明度、悬停这类不移动位置的反馈。
    static let quick = Animation.easeOut(duration: 0.16)
    /// 手机底部栏那一格的按下与回弹。
    static let press = Animation.easeOut(duration: 0.1)
    /// 按下：快、不回弹，手指一落就到位。
    static let pressDown = Animation.spring(duration: 0.14, bounce: 0)
    /// 松开：稍慢、带一点回弹，像纸被放开时弹回来。
    static let pressUp = Animation.spring(duration: 0.34, bounce: 0.32)
    /// 列表里一行出现、消失：淡入并从 96% 放大到位，消失反过来；位置由列表自己的动画挪。
    static let item = AnyTransition.opacity.combined(with: .scale(scale: 0.96))

    /// 减弱动态效果时，空间动画换成短淡入淡出。
    static func spatial(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

/// 按压反馈只有这几类（`PressStyle` 按种类、`RowPressStyle`、系统的主按钮）。调用处只说按的是哪一种（`Press`），两端写法相同；
/// 每种在各平台长什么样只在 `PressFeedback` 定。
/// 手机：按下快、松开带一点回弹，按种类缩到不同比例，按下有一下轻触感；行只亮底不缩放（一屏几十行，缩放会让列表显得软）；减弱动态效果时只降透明度。
/// Mac 照原生控件（访达、邮件、备忘录的按钮、列表与卡片都这样）：按下的那一刻变淡（卡片压暗一层），松开即复原，
/// 不缩放、不回弹、不震动——缩放与回弹是触屏的习惯，在指针下显得软、慢；触控板的震动在 macOS 只给对齐这类反馈，点按钮不震。
enum Press {
    /// 圆钮、图标按钮。
    case button
    /// 标准按钮、胶囊。
    case control
    /// 整张卡片。
    case card
    /// 整宽的一条（虚线框的"写一条提示词"）。
    case wide
}

/// 按钮的按下反馈，按种类（`Press`）。
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
    /// 按钮按下时内容的透明度；卡片不变淡（整张变淡像停用），压暗一层。
    private static let dimmed = 0.6
    private static let shade = 0.05

    /// 原生控件的高亮没有过渡：按下、松开都在那一帧到位，外层的动画（列表挪位、开合）也不带它。
    /// 每种只挂自己要的那一个效果：亮度滤镜挂在每颗按钮上，按钮里的字都要另画一遍。
    func body(content: Content) -> some View {
        let active = pressed && isEnabled
        if kind == .card {
            content.brightness(active ? (palette.dark ? Self.shade : -Self.shade) : 0).animation(nil, value: active)
        } else {
            content.opacity(active ? Self.dimmed : 1).animation(nil, value: active)
        }
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
        }
    }

    func body(content: Content) -> some View {
        let active = pressed && isEnabled
        let card = kind == .card
        content
            .scaleEffect(active && !reduceMotion ? scale : 1)
            .brightness(active && card ? -0.02 : 0)
            .opacity(active && (reduceMotion || !card) ? 0.9 : 1)
            .animation(active ? Motion.pressDown : Motion.pressUp, value: active)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: active) { _, now in now }
    }
    #endif
}

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
}

/// 控件只有一套外形与按压实现，空态、绑定引导和搜索栏共用；签名色只给主动作，其余是墨色。
struct ControlButtonStyle: ButtonStyle {
    enum Kind { case primary, highlight, secondary, quiet, circular }
    var kind = Kind.secondary
    var compact = false
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        surface(configuration.label)
            .modifier(PressFeedback(pressed: configuration.isPressed, kind: kind == .circular ? .button : .control))
            .opacity(isEnabled ? 1 : 0.45)
    }

    @ViewBuilder private func surface(_ label: ButtonStyleConfiguration.Label) -> some View {
        if kind == .circular {
            label
                .font(Typography.body.weight(.medium))
                .foregroundStyle(palette.ink)
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
                .glass(in: .circle, interactive: true)
        } else {
            label
                .font((compact ? Typography.meta : Typography.secondary).weight(.medium))
                .foregroundStyle(kind == .primary ? palette.onSignature : kind == .highlight ? palette.signature : palette.ink)
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.vertical, 6)
                .frame(minHeight: compact ? ControlMetrics.compactHeight : ControlMetrics.height)
                .background(kind == .primary ? palette.signatureFill : kind == .highlight ? palette.selection : kind == .quiet ? .clear : palette.fill, in: .capsule)
                .overlay { Capsule().strokeBorder(kind == .secondary ? palette.hair : kind == .highlight ? palette.signature.opacity(0.18) : .clear, lineWidth: ControlMetrics.stroke) }
                #if os(iOS)
                .frame(minHeight: ControlMetrics.height)
                #endif
                .contentShape(.capsule)
        }
    }
}
