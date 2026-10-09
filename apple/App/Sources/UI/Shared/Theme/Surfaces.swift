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
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }
}

private struct PaperSurface: ViewModifier {
    let radius: CGFloat
    let lifted: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(LinearGradient(colors: [palette.paperLit, palette.paper], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)), in: shape)
            .overlay(shape.strokeBorder(palette.paperEdge(lifted: lifted)))
            // 上沿一线高光：纸边像被光擦过，与玻璃同一种光。只画上沿一条实色细线：渐变描边由 CPU 按整张卡的面积铺渐变，
            // 卡片一变宽（侧栏开合、拉窗口）整面墙每张都要重画，大库里开合侧栏的第一帧因此卡上百毫秒
            .overlay(alignment: .top) { palette.sheen.frame(height: 1).padding(.horizontal, radius).padding(.top, 1) }
            // 平放的纸只用描边：每张卡一个模糊阴影，侧栏开合时整面墙每帧都要重画这些阴影
            .shadow(color: .black.opacity(palette.dark || !lifted ? 0 : 0.08), radius: lifted ? 10 : 0, y: lifted ? 6 : 0)
    }
}

extension Palette {
    /// 纸面的描边色。
    func paperEdge(lifted: Bool = false) -> Color { dark ? Color.white.opacity(lifted ? 0.14 : 0.07) : hair }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(palette.paper, in: shape)
                .overlay(shape.stroke(palette.hair))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        interactive ? .regular.interactive() : .regular
    }
}

/// 动效：只有卡片 ↔ 纸是大幅空间过渡；其余为短淡入淡出。减弱动态效果时一律直接到终态或只淡入淡出。
/// 动效 token（Mac 与 iOS 共用）：位置与尺寸用不回弹的临界阻尼弹簧，都在 300ms 以内；弹簧从当前呈现值继续，天然可打断。
/// 只有按压松开带一点回弹（`pressUp`），给手感；常驻的循环动效只给 Agent 在工作与话在路上（`PiStateDot`）和进行中的流光，都在 `LoopLayer`（Core Animation），离屏即停。
enum Motion {
    /// 短动效：列表里挪位置、面板、浮层、切换。
    static let snappy = Animation.spring(duration: 0.25, bounce: 0)
    /// 卡片在墙上挪位（同列下移、新卡入场）：定长 0.24s，弹簧的尾巴会让实际时长超过 300ms。
    static let move = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
    /// 卡片放大成纸页。
    static let paper = Animation.spring(duration: 0.28, bounce: 0)
    /// 纸页缩回卡片：出场约为进场的 75%。用定长曲线而不是弹簧：完成回调要准时落在纸到位的那一刻，
    /// 弹簧的完成要等尾巴收敛，纸会以空白状态在原卡上多停一两帧。
    static let paperCloseDuration = 0.22
    static let paperClose = Animation.timingCurve(0.3, 0, 0.1, 1, duration: paperCloseDuration)
    static let panel = snappy
    /// 颜色、透明度、悬停这类不移动位置的反馈。
    static let quick = Animation.easeOut(duration: 0.16)
    /// 点下要打开的卡：缩到这个比例（Mac 的 `CardOpenStyle`），纸页从这个样子起飞。
    static let pressScale: CGFloat = 0.98
    /// 点下的那一帧先直接缩到这里，余下的再缓动：动画的第一帧进度为零，全靠缓动的话点下那一帧看不出变化。
    static let pressKick: CGFloat = 0.99
    /// Mac 点开卡片（`CardOpenStyle`）的按下与回弹。
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

/// 按压反馈只有这几类（`PressStyle`、`CardPressStyle`、`RowPressStyle`、系统的主按钮），按下快、松开带一点回弹；
/// 圆钮与卡片按下有一下轻触感，行只亮底不缩放（一屏几十行，缩放会让列表显得软）。减弱动态效果时只降透明度。
enum Press {
    /// 圆钮、图标按钮。
    static let button: CGFloat = 0.88
    /// 标准按钮、胶囊。
    static let control: CGFloat = 0.95
    /// 整张卡片：大面积只缩一点，不然文字发虚。
    static let card: CGFloat = 0.97
}

/// 圆钮、图标按钮与胶囊的按下反馈：弹簧缩放 + 一下轻触感。`scale` 见 `Press`。
struct PressStyle: ButtonStyle {
    var scale: CGFloat = Press.control

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale, haptic: true)
    }
}

/// 整张卡片的按下反馈：缩到 97%、略压暗，松开弹回，按下一下轻触感。
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: Press.card, haptic: true, darken: true)
    }
}

private struct PressBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    var haptic = false
    var darken = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .brightness(pressed && darken ? -0.02 : 0)
            .opacity(pressed && (reduceMotion || !darken) ? 0.9 : 1)
            .animation(pressed ? Motion.pressDown : Motion.pressUp, value: pressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: pressed) { _, now in haptic && now }
    }
}
