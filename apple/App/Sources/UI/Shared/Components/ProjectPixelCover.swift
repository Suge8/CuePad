import SwiftUI

nonisolated enum ProjectCoverStyle {
    case whale, shark, jellyfish, turtle, fox, cat, penguin, owl
    case monstera, cactus, mushroom, flower
}

/// 项目卡的静态像素插画；只复用主题已采样的颜料路径，不在绘制时计算图层或抖色。
struct ProjectPixelCover: View {
    let style: ProjectCoverStyle

    var body: some View {
        let pattern = ProjectPixelPattern.pattern(for: style)
        Canvas(rendersAsynchronously: true) { context, size in
            context.scaleBy(x: size.width / CGFloat(ProjectPixelPattern.columns),
                            y: size.height / CGFloat(ProjectPixelPattern.rows))
            for fill in pattern.fills {
                context.fill(fill.path, with: .color(fill.color), style: FillStyle(antialiased: false))
            }
        }
        .background(pattern.ground)
        .aspectRatio(CGFloat(ProjectPixelPattern.columns) / CGFloat(ProjectPixelPattern.rows), contentMode: .fit)
        .accessibilityHidden(true) // 合并项目卡内排除装饰，另包容器会把封面挡在合并之外。
        .allowsHitTesting(false)
    }
}
