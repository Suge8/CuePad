import CueStore
import SwiftUI

/// 项目图标与颜色的选择（Mac 与 iOS 的项目表单共用）。`cell` 是每个格子的边长：Mac 30，触屏 44。
/// 两组都按拿到的宽度换行排：列数取放得下的最多，列宽均分整行、格子在列里居中，任何宽度下两侧对称。
struct ProjectStylePicker: View {
    @Binding var icon: String
    @Binding var color: String
    var cell: CGFloat
    @Environment(\.palette) private var palette

    /// 可选颜色：存储值 → 读屏与提示用的颜色名。
    static let colors: [(hex: String, name: String)] = [
        ("#D9774B", "橙色"), ("#C9A227", "黄色"), ("#5E9E5A", "绿色"), ("#3F8FB8", "蓝色"),
        ("#6A6FD1", "靛蓝"), ("#A260C4", "紫色"), ("#D0607D", "粉色"), ("#8A8A84", "灰色"),
    ]

    private static let spacing: CGFloat = 6

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cell), spacing: Self.spacing)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(ProjectGlyph.choices, id: \.symbol) { choice in
                    let symbol = choice.symbol, selected = icon == symbol
                    let shape = RoundedRectangle(cornerRadius: cell / 4, style: .continuous)
                    Button { icon = symbol } label: {
                        Image(systemName: symbol).frame(width: cell, height: cell)
                            // 选中：墨色描边加浅底，深浅色下都清楚，不靠图标本身的颜色
                            .background(selected ? palette.selection : .clear, in: shape)
                            .overlay { if selected { shape.strokeBorder(palette.ink, lineWidth: 2) } }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.projectTint(color))
                    .accessibilityLabel("图标：\(choice.name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(choice.name)
                }
            }
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(Self.colors, id: \.hex) { choice in
                    let hex = choice.hex, selected = color == hex
                    Button { color = hex } label: {
                        Circle().fill(Palette.projectTint(hex)).frame(width: cell * 0.66, height: cell * 0.66)
                            .overlay { if selected { Circle().strokeBorder(palette.ink, lineWidth: 2).padding(-4) } }
                            .frame(width: cell, height: cell)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("颜色：\(choice.name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(choice.name)
                }
            }
        }
    }
}

extension Workspace {
    /// 新建（`project` 为 nil）或更新项目的名称、图标与颜色；返回项目 id。
    /// `intro` 是项目的一句话介绍，空白即没有。
    func saveProject(_ project: Project?, name: String, intro: String, icon: String, color: String) async throws -> UUID {
        let store = services.store, intro = intro.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let id = if let existing = project?.id { existing } else { try await store.createProject(name: name, color: color, icon: icon).id }
        try await store.updateProject(id) { $0.name = name; $0.intro = intro; $0.icon = icon; $0.color = color }
        return id
    }
}
