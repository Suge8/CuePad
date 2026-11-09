import CueStore
import SwiftUI

struct ProjectStylePicker: View {
    @Binding var icon: ProjectIcon
    @Binding var color: String
    var cell: CGFloat
    @Environment(\.palette) private var palette

    private static let spacing: CGFloat = 6
    private static let glyph: CGFloat = 0.56

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cell), spacing: Self.spacing)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(ProjectIcon.allCases, id: \.self) { choice in
                    let selected = icon == choice
                    Button { icon = choice } label: {
                        Image(.project(choice)).font(.system(size: cell * Self.glyph, weight: .medium)).frame(width: cell, height: cell)
                            .modifier(Picked(selected: selected))
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
                            .modifier(Picked(selected: selected))
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

private struct Picked: ViewModifier {
    let selected: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: Radius.row))
            .contentShape(.rect)
    }
}
