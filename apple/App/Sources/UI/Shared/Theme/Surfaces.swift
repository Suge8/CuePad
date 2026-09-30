import SwiftUI

extension View {
    /// 纸面：实底 + 1px 半透明描边 + 浅色下两层柔光（深色只留描边）。
    func paper(radius: CGFloat = 14, lifted: Bool = false) -> some View {
        modifier(PaperSurface(radius: radius, lifted: lifted))
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
            .overlay(shape.strokeBorder(palette.dark ? Color.white.opacity(lifted ? 0.14 : 0.07) : palette.hair))
            // 平放的纸只用描边：每张卡一个模糊阴影，侧栏开合时整面墙每帧都要重画这些阴影
            .shadow(color: .black.opacity(palette.dark || !lifted ? 0 : 0.08), radius: lifted ? 10 : 0, y: lifted ? 6 : 0)
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
enum Motion {
    static let paper = Animation.spring(duration: 0.45, bounce: 0.1)
    static let panel = Animation.spring(duration: 0.3, bounce: 0)
    static let quick = Animation.easeOut(duration: 0.16)

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
