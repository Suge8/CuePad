import CueStore
import SwiftUI

/// 项目图标与颜色的选择（Mac 与 iOS 的项目表单共用）。`cell` 是每个格子的边长：Mac 30，触屏 44。
struct ProjectStylePicker: View {
    @Binding var icon: String
    @Binding var color: String
    var cell: CGFloat

    /// 可选颜色：存储值 → 读屏与提示用的颜色名。
    static let colors: [(hex: String, name: String)] = [
        ("#D9774B", "橙色"), ("#C9A227", "黄色"), ("#5E9E5A", "绿色"), ("#3F8FB8", "蓝色"),
        ("#6A6FD1", "靛蓝"), ("#A260C4", "紫色"), ("#D0607D", "粉色"), ("#8A8A84", "灰色"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 6)], spacing: 6) {
                ForEach(ProjectGlyph.choices, id: \.symbol) { choice in
                    let symbol = choice.symbol
                    Button { icon = symbol } label: {
                        Image(systemName: symbol).frame(width: cell, height: cell)
                            .background(icon == symbol ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: cell / 4))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.projectTint(color))
                    .accessibilityLabel("图标：\(choice.name)")
                    .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                    .help(choice.name)
                }
            }
            HStack(spacing: cell / 3) {
                ForEach(Self.colors, id: \.hex) { choice in
                    let hex = choice.hex
                    Button { color = hex } label: {
                        Circle().fill(Palette.projectTint(hex)).frame(width: cell * 0.66, height: cell * 0.66)
                            .overlay { if color == hex { Circle().stroke(.primary, lineWidth: 2).padding(-3) } }
                            .frame(width: cell, height: cell)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("颜色：\(choice.name)")
                    .accessibilityAddTraits(color == hex ? .isSelected : [])
                    .help(choice.name)
                }
            }
        }
    }
}

extension Workspace {
    /// 新建（`project` 为 nil）或更新项目的名称、图标与颜色；返回项目 id。
    func saveProject(_ project: Project?, name: String, icon: String, color: String) async throws -> UUID {
        if let id = project?.id {
            try await services.store.updateProject(id) { $0.name = name; $0.icon = icon; $0.color = color }
            return id
        }
        return try await services.store.createProject(name: name, color: color, icon: icon).id
    }
}
