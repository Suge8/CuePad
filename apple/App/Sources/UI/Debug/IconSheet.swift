#if os(iOS) && DEBUG
import SwiftUI

/// 图标样张（`-CuePadScene icons`，iPad 竖屏，一屏 24 行，`-CuePadSheetPage` 翻页）：正在画的这一批墨块符号经 `Icon` 取图，每个四档字号（12、17、22、34pt）各画两遍——
/// 左边是 App 里的样子（层级渲染，点睛是次一级），中间是单色（系统菜单、工具栏里的样子，所有层同色，靠刻缝分开），
/// 项目图标右边再按每种项目色各画一个（22pt）。
struct IconSheet: View {
    @Environment(\.palette) private var palette

    private static let icons: [(String, Icon)] = ProjectIcon.allCases.map { ($0.name, .project($0)) } + [("菜单栏", .menuBar)]
    private static let sizes: [CGFloat] = [12, 17, 22, 34]
    /// 一屏放 `perPage` 行；多出来的配 `-CuePadSheetPage 2` 起看后面的。
    private static let perPage = 24
    private static var page: ArraySlice<(String, Icon)> {
        let start = (max(DebugScene.defaults.integer(forKey: "CuePadSheetPage"), 1) - 1) * perPage
        return icons[min(start, icons.count)..<min(start + perPage, icons.count)]
    }

    var body: some View {
        column(Self.page)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.desk)
            .foregroundStyle(palette.ink)
    }

    private func column(_ icons: ArraySlice<(String, Icon)>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
            ForEach(icons, id: \.0) { name, icon in
                GridRow(alignment: .center) {
                    Text(name).font(.caption2.monospaced()).foregroundStyle(palette.ink2).lineLimit(1).fixedSize()
                    ForEach(Self.sizes, id: \.self) { Image(icon).font(.system(size: $0)) }
                    Color.clear.frame(width: 24, height: 1)
                    ForEach(Self.sizes, id: \.self) { size in
                        if let image = icon.platformImage?.applyingSymbolConfiguration(.init(pointSize: size)) {
                            Image(uiImage: image.withRenderingMode(.alwaysTemplate))
                        }
                    }
                    if case .project = icon {
                        Color.clear.frame(width: 24, height: 1)
                        ForEach(Palette.projectColors, id: \.stored) { Image(icon).font(.system(size: 22)).foregroundStyle(palette.project($0.stored)) }
                    }
                }
            }
        }
    }
}
#endif
