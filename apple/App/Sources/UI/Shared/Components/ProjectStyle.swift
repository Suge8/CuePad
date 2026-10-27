import CueStore
import SwiftUI

/// 项目图标与颜色的选择（Mac 与 iOS 的项目表单共用）。`cell` 是每个格子的边长：Mac 30，触屏 44。
/// 两组都按拿到的宽度换行排：列数取放得下的最多，列宽均分整行、格子在列里居中，任何宽度下两侧对称。
struct ProjectStylePicker: View {
    @Binding var icon: ProjectIcon
    @Binding var color: String
    var cell: CGFloat
    @Environment(\.palette) private var palette

    private static let spacing: CGFloat = 6
    /// 图标字号占格子边长的比例：Mac 约 17、触屏约 24。
    private static let glyph: CGFloat = 0.56

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cell), spacing: Self.spacing)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(ProjectIcon.allCases, id: \.self) { choice in
                    let selected = icon == choice
                    Button { icon = choice } label: {
                        Image(.project(choice)).font(.system(size: cell * Self.glyph, weight: .medium)).frame(width: cell, height: cell)
                            .modifier(Picked(selected: selected, cornerRadius: cell / 4))
                    }
                    .buttonStyle(PressStyle(.button))
                    .foregroundStyle(palette.project(color))
                    .accessibilityLabel("图标：\(choice.name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(choice.name)
                }
            }
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(Palette.projectColors, id: \.stored) { choice in
                    let stored = choice.stored, selected = color == stored
                    Button { color = stored } label: {
                        Circle().fill(palette.project(stored)).frame(width: cell * 0.66, height: cell * 0.66)
                            .frame(width: cell, height: cell)
                            .modifier(Picked(selected: selected, cornerRadius: cell / 4))
                    }
                    .buttonStyle(PressStyle(.button))
                    .accessibilityLabel("颜色：\(choice.name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(choice.name)
                }
            }
        }
    }
}

/// 图标格与颜色格选中同一个样子（docs/ui.md「同一状态处处同一个样子」）：选中是一块底（`selection`），外加一圈签名色细线，
/// 浅底上的项目色圆点也框得出来，深浅色下都清楚，不靠图标本身的颜色。
private struct Picked: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(selected ? palette.selection : .clear, in: shape)
            .overlay { if selected { shape.strokeBorder(palette.signature, lineWidth: 1.5) } }
            .contentShape(.rect)
    }
}
