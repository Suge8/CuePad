#if os(iOS) && DEBUG
import SwiftUI

/// 图标总览（`-CuePadScene icons`，iPad 竖屏一屏）：生成器写出的全部墨块符号（`InkSymbols`），每个画两遍——左边是 App 里的样子
/// （层级渲染，点睛是次一级），右边是单色（系统菜单、工具栏里的样子，所有层同色，靠刻缝分开）；下面是项目表单的全部项目图标 × 8 种项目色。
struct IconSheet: View {
    @Environment(\.palette) private var palette

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)
    private static let symbolSize: CGFloat = 22
    private static let projectSize: CGFloat = 18
    /// 项目图标一组几列（同 Mac 项目表单一行）。
    private static let perGroup = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                ForEach(InkSymbols.names, id: \.self) { name in
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Image(name).symbolRenderingMode(.hierarchical)
                            Image(name).symbolRenderingMode(.monochrome)
                        }
                        .font(.system(size: Self.symbolSize))
                        Text(name.dropFirst(4)).font(.system(size: 8).monospaced()).foregroundStyle(palette.ink2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(stride(from: 0, to: ProjectIcon.allCases.count, by: Self.perGroup)), id: \.self) { start in
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Palette.projectColors, id: \.stored) { color in
                            GridRow {
                                ForEach(ProjectIcon.allCases[start ..< min(start + Self.perGroup, ProjectIcon.allCases.count)], id: \.self) {
                                    Image(.project($0)).foregroundStyle(palette.project(color.stored))
                                }
                            }
                        }
                    }
                    .font(.system(size: Self.projectSize))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
        .foregroundStyle(palette.ink)
    }
}
#endif
