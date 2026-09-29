#if os(macOS)
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
            .shadow(color: .black.opacity(palette.dark ? 0 : (lifted ? 0.08 : 0.04)), radius: lifted ? 10 : 3, y: lifted ? 6 : 1)
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
#endif
