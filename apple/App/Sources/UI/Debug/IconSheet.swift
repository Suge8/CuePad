#if os(iOS) && DEBUG
import SwiftUI

/// 图标样张（`-CuePadScene icons`，iPad 竖屏一屏放得下）：正在画的这一批墨块符号经 `Icon` 取图，每个四档字号（12、17、22、34pt）各画两遍——
/// 左边是 App 里的样子（层级渲染，点睛是次一级），右边是单色（系统菜单、工具栏里的样子，所有层同色，靠刻缝分开）。
struct IconSheet: View {
    @Environment(\.palette) private var palette

    private static let icons: [(String, Icon)] = [
        ("complete", .complete), ("reopen", .reopen), ("restore", .restore), ("start", .start), ("indent", .indent), ("outdent", .outdent),
        ("link", .link), ("unlink", .unlink), ("folder", .folder), ("newProject", .newProject), ("unbindFolder", .unbindFolder),
        ("folderMissing", .folderMissing), ("resource", .resource), ("pin", .pin), ("unpin", .unpin), ("copy", .copy), ("conflict", .conflict),
        ("share", .share), ("saveAsIdea", .saveAsIdea), ("write", .write), ("rename", .rename), ("choose", .choose),
        ("all", .all), ("allSessions", .allSessions), ("allProjects", .allProjects), ("filter", .filter), ("extensionNote", .extensionNote),
    ]
    private static let sizes: [CGFloat] = [12, 17, 22, 34]

    var body: some View {
        column(Self.icons[...])
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
                }
            }
        }
    }
}
#endif
