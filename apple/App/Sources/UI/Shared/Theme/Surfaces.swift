import SwiftUI

extension View {
    /// 纸面：从上沿极轻地亮到纸色的实底 + 上沿一线高光 + 1px 半透明描边；抬起的纸浅色下多一层柔影（深色只留描边）。
    /// `wash`：要你看的那张纸铺这种状态的淡底（`PiShown.wash`），代替纸色。
    func paper(radius: CGFloat = 14, lifted: Bool = false, wash: Color? = nil) -> some View {
        modifier(PaperSurface(radius: radius, lifted: lifted, wash: wash))
    }

    /// 计数变化时数字滚动过去（增大往上滚、减小往下滚），不整块换字。
    func counting(_ value: Int) -> some View {
        contentTransition(.numericText(value: Double(value))).animation(Motion.snappy, value: value)
    }

    /// 控件层玻璃；"降低透明度"开启时退回实底。玻璃不叠玻璃：调用方不在玻璃里再套玻璃。
    /// `ink`：默认垫实底（写着字的玻璃）；只有图标的圆钮给 `.clear`（`GlassInk`）。
    func glass<S: Shape>(in shape: S, interactive: Bool = false, ink: GlassInk = .solid) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, ink: ink))
    }
}

/// 玻璃上的字要多好读。
enum GlassInk {
    case clear
    /// 写着字的（默认；顶栏标题、输入框、搜索框、提示横幅、状态行）：玻璃里垫九成实的页面底色，边缘仍是玻璃的光。内容一直滚到这些玻璃后面，
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
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .environment(\.rowSurface, wash ?? palette.paper)
            // 影子只挂在底那块形状上：挂在整块内容上时，里面的字、图与按钮要先离屏合成一遍再糊影子，转场与按压的每帧都重算。
            // 平放的纸只用描边：每张卡一个模糊阴影，侧栏开合时整面墙每帧都要重画这些阴影
            .background {
                Group { if let wash { shape.fill(wash) } else { shape.fill(palette.paperFill) } }
                    .shadow(color: palette.dark || !lifted ? .clear : palette.shadow, radius: lifted ? 10 : 0, y: lifted ? 6 : 0)
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
        } else if ink == .solid {
            // 实底垫在哪一层两个平台不同：Mac 的玻璃会在它下面那层上再压暗、提亮一档，只垫在玻璃下面整块发灰，所以玻璃里要垫；
            // 玻璃下面也垫，不然浮在桌面上的（Cue 条、菜单栏面板）透出壁纸的颜色。iOS 的顶栏把玻璃连同里面的东西提到它那一层上画、
            // 再提亮一档，垫在里面的反而发灰，所以只垫在玻璃下面
            #if os(macOS)
            content.background(palette.solidGlass, in: shape).glassEffect(glass, in: shape).background(palette.solidGlass, in: shape)
            #else
            content.glassEffect(glass, in: shape).background(palette.solidGlass, in: shape)
            #endif
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    /// 全 App 自绘玻璃都是 `.regular`：内容一直滚到顶栏、回复框后面，玻璃是唯一的遮挡，栏后面不再垫模糊或渐变带。
    /// 否决了 `.clear`（加淡色 tint 也一样）：我们玻璃后面是文字，它几乎不糊开背后的字，栏上的标题、标签与问题卡和背后的字叠在一起读不出
    /// （系统规范也只把 clear 用在照片、视频这类背景上）；系统自己的返回钮与工具栏圆钮也是 regular，两种并排会不一致。
    private var glass: Glass {
        guard ink == .solid else { return .regular.interactive(interactive) }
        return .regular.tint(palette.glassTint).interactive(interactive)
    }
}

/// 动效：没有大幅的空间过渡（Mac 打开卡片是编辑页原地淡入）；位置与尺寸只在列表、面板里小幅挪动，其余为短淡入淡出。
/// 减弱动态效果时空间动画直接到终态（`spatial`）；确要交代"变了"的地方由调用处换身份、用 `crossfade` 整块交叉淡入淡出。
/// 动效 token（Mac 与 iOS 共用）：位置与尺寸用不回弹的临界阻尼弹簧，都在 300ms 以内；弹簧从当前呈现值继续，天然可打断。
/// 只有按压松开带一点回弹（`pressUp`），给手感；常驻的循环动效只给 Agent 在工作与话在路上（`PiStateDot`）和进行中的流光，都在 `LoopLayer`（Core Animation），离屏即停。
/// 超过 300ms 的只有 Cue 与会话之间接力的那一下（`CueRelayStage`），时长与理由在它那里。
enum Motion {
    /// 短动效：列表里挪位置、面板、浮层、切换。
    static let snappy = Animation.spring(duration: 0.25, bounce: 0)
    /// 卡片在墙上挪位（同列下移、新卡入场）：定长 0.24s，弹簧的尾巴会让实际时长超过 300ms。
    static let move = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
    /// iPhone 点按换去处：根上那一条页滑过去与底部那一排两块玻璃换形同一个（`HomePager`、`DockBar`），一起到位；比列表里挪位置走得长，看得清从哪到哪，仍在 300ms 内。
    static let dock = Animation.spring(duration: 0.3, bounce: 0)
    /// 颜色、透明度、悬停这类不移动位置的反馈。
    static let quick = Animation.easeOut(duration: 0.16)
    /// 按下：快、不回弹，手指一落就到位。
    static let pressDown = Animation.spring(duration: 0.14, bounce: 0)
    /// 松开：稍慢、带一点回弹，像纸被放开时弹回来。
    static let pressUp = Animation.spring(duration: 0.34, bounce: 0.32)
    /// 列表里一行出现、消失：淡入并从 96% 放大到位，消失反过来；位置由列表自己的动画挪。
    static let item = AnyTransition.opacity.combined(with: .scale(scale: 0.96))

    /// 减弱动态效果时的整块交叉淡入淡出：只配换了身份的视图用（新旧两块各自淡入淡出），同一个视图上用它照样会插值位置与尺寸。
    static let crossfade = Animation.easeInOut(duration: 0.15)
    /// 同一处先后换两样东西（一句状态换另一句、横幅让回页头）：旧的这么久淡完，新的晚这么久再出，不叠着交叉淡。
    static let handOff: Double = 0.08

    /// 位置、尺寸、旋转的动画；减弱动态效果时没有动画、直接到终态——一个动画事务里分不出只淡不挪，换曲线照样插值。
    static func spatial(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// 按压反馈只有这几类（`PressStyle` 按种类、列表的行 `RowStyle`、系统的主按钮）。调用处只说按的是哪一种（`Press`），两端写法相同；
/// 每种在各平台长什么样只在 `PressFeedback` 定，行的底只在 `RowMetrics` 定。
/// 手机：按下快、松开带一点回弹，按种类缩到不同比例，按下有一下轻触感；行只亮底不缩放（一屏几十行，缩放会让列表显得软）；减弱动态效果时只降透明度。
/// Mac 照原生控件（访达、邮件、备忘录的按钮、列表与卡片都这样）：按下的那一刻变淡（卡片压暗一层），松开即复原，
/// 不缩放、不回弹、不震动——缩放与回弹是触屏的习惯，在指针下显得软、慢；触控板的震动在 macOS 只给对齐这类反馈，点按钮不震。
/// Mac 悬停：指针一进来就有回应（同 macOS 26 工具栏玻璃钮的悬停，与 Linear、Raycast、Arc），淡入淡出 `Motion.quick`、不挪位置不缩放：
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
        .animation(Motion.quick, value: lit)
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
            .animation(active ? Motion.pressDown : Motion.pressUp, value: active)
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

/// 按钮悬停那层淡底的形状：随按钮的框——方的是圆、矮的是胶囊（同圆钮与胶囊控件），高的是圆角不超过 `maxRadius` 的圆角矩形。
nonisolated private struct HoverShape: Shape {
    private static let maxRadius: CGFloat = 18
    /// 字里行间的小钮（`Press.inline`）的悬停底比字宽出的一圈。
    static let inlineOutset = EdgeInsets(top: -2, leading: -6, bottom: -2, trailing: -6)

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(min(rect.width, rect.height) / 2, Self.maxRadius), style: .continuous)
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlSurface(kind: kind, compact: compact, destructive: configuration.role == .destructive))
            .modifier(PressFeedback(pressed: configuration.isPressed, kind: kind == .circular ? .button : .control))
            .opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
    }
}

/// 控件的外形（`ControlButtonStyle` 的样子，不含按压）。
struct ControlSurface: ViewModifier {
    var kind = ControlButtonStyle.Kind.secondary
    var compact = false
    var destructive = false
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
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
