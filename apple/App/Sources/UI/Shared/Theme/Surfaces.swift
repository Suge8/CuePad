import SwiftUI

extension View {
    /// 纸面：实底 + 1px 半透明描边 + 浅色下两层柔光（深色只留描边）。
    func paper(radius: CGFloat = 14, lifted: Bool = false) -> some View {
        modifier(PaperSurface(radius: radius, lifted: lifted))
    }

    /// 一张纸面里的一行（懒加载列表逐行画，拼起来与 `paper` 一张纸一样）：首行带上圆角与上边，末行带下圆角与下边。
    func paperSlice(first: Bool, last: Bool, radius: CGFloat = 14) -> some View {
        modifier(PaperSlice(first: first, last: last, radius: radius))
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
            .background(palette.paper, in: shape)
            .overlay(shape.strokeBorder(palette.paperEdge(lifted: lifted)))
            // 平放的纸只用描边：每张卡一个模糊阴影，侧栏开合时整面墙每帧都要重画这些阴影
            .shadow(color: .black.opacity(palette.dark || !lifted ? 0 : 0.08), radius: lifted ? 10 : 0, y: lifted ? 6 : 0)
    }
}

extension Palette {
    /// 纸面的描边色。
    func paperEdge(lifted: Bool = false) -> Color { dark ? Color.white.opacity(lifted ? 0.14 : 0.07) : hair }
}

private struct PaperSlice: ViewModifier {
    let first: Bool
    let last: Bool
    let radius: CGFloat
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let top = first ? radius : 0, bottom = last ? radius : 0
        content
            .background(palette.paper, in: UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous))
            .overlay(SliceEdge(first: first, last: last, radius: radius).stroke(palette.paperEdge(), lineWidth: 1))
    }
}

/// 一行的外沿：左右两边，首行加上沿与上圆角，末行加下沿与下圆角（中间行没有横线，拼起来是一圈完整的描边）。
nonisolated private struct SliceEdge: Shape {
    let first: Bool
    let last: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let top = first ? radius : 0, bottom = last ? radius : 0
        var path = Path()
        // 左边从下往上，过上沿，再右边从上往下，过下沿
        path.move(to: CGPoint(x: r.minX, y: last ? r.maxY - bottom : rect.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: first ? r.minY + top : rect.minY))
        if first {
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + top, y: r.minY), radius: top)
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + top), radius: top)
        } else {
            path.move(to: CGPoint(x: r.maxX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: r.maxX, y: last ? r.maxY - bottom : rect.maxY))
        if last {
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - bottom, y: r.maxY), radius: bottom)
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bottom), radius: bottom)
        }
        return path
    }
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
/// 动效 token（Mac 与 iOS 共用）：一律不回弹的临界阻尼弹簧，都在 300ms 以内；弹簧从当前呈现值继续，天然可打断。
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
    /// 按下与松开回弹。
    static let press = Animation.easeOut(duration: 0.1)

    /// 减弱动态效果时，空间动画换成短淡入淡出。
    static func spatial(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

/// 按下反馈：按下 80ms 缩小（尺寸越小缩得越多，每边约 1.5–2px），松开 160ms 回弹，都是缓出；
/// 减弱动态效果时只降透明度。`scale`：图标按钮 0.9，标准按钮 0.96，宽按钮 0.98。
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale)
    }

    private struct PressBody: View {
        let configuration: Configuration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .scaleEffect(pressed && !reduceMotion ? scale : 1)
                .opacity(pressed ? 0.8 : 1)
                .animation(pressed ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16), value: pressed)
        }
    }
}

/// 整张卡片的按下反馈：不缩放（大面积缩放会让文字发虚），下沉 1px。
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .brightness(configuration.isPressed ? -0.015 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
