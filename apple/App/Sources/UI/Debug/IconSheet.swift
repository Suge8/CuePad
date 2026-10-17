#if os(iOS) && DEBUG
import SwiftUI

/// 图标样张（`-CuePadScene icons`，iPad 竖屏一屏放得下）：这一批墨块符号经 `Icon` 取图，每个四档字号（12、17、22、34pt）各画两遍——
/// 左边是 App 里的样子（层级渲染，点睛是次一级），右边是单色（系统菜单、工具栏里的样子，所有层同色，靠刻缝分开）。
struct IconSheet: View {
    @Environment(\.palette) private var palette

    private static let icons: [(String, Icon)] = [
        ("waiting", .waiting), ("failure", .failure), ("undelivered", .undelivered), ("unknown", .unknown), ("picked", .picked),
        ("cueAsking", .cueAsking), ("ended", .ended), ("interrupted", .interrupted), ("yourTurn", .yourTurn), ("fresh", .fresh),
        ("agent", .agent), ("needsReload", .needsReload), ("syncNow", .syncNow), ("replied", .replied),
        ("alertsOn", .alertsOn), ("alertsOff", .alertsOff), ("syncStarting", .syncStarting), ("synced", .synced), ("syncing", .syncing),
        ("syncTrouble", .syncTrouble), ("syncPaused", .syncPaused), ("uploadLocal", .uploadLocal), ("replaceWithCloud", .replaceWithCloud),
        ("syncOff", .syncOff), ("syncRestricted", .syncRestricted),
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
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
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
