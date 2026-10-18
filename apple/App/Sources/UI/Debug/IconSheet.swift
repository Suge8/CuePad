#if os(iOS) && DEBUG
import SwiftUI

/// 图标样张（`-CuePadScene icons`，iPad 竖屏，一屏 24 行，`-CuePadSheetPage` 翻页）：正在画的这一批墨块符号经 `Icon` 取图，每个四档字号（12、17、22、34pt）各画两遍——
/// 左边是 App 里的样子（层级渲染，点睛是次一级），右边是单色（系统菜单、工具栏里的样子，所有层同色，靠刻缝分开）。
struct IconSheet: View {
    @Environment(\.palette) private var palette

    private static let icons: [(String, Icon)] = [
        ("memory", .memory), ("wakeEnabled", .wakeEnabled), ("wakeMessage", .wakeMessage), ("wakeActivity", .wakeActivity), ("wakeIdle", .wakeIdle), ("wakeReminder", .wakeReminder),
        ("wakeSettings", .wakeSettings), ("mail", .mail), ("profile", .profile), ("name", .name), ("autoApprove", .autoApprove), ("hotkey", .hotkey),
        ("talkToCue", .talkToCue), ("appearance", .appearance), ("testConnection", .testConnection), ("updates", .updates),
        ("web", .web), ("markdown", .markdown), ("video", .video), ("audio", .audio), ("pdf", .pdf), ("document", .document), ("spreadsheet", .spreadsheet),
        ("presentation", .presentation), ("model", .model), ("plainText", .plainText),
        ("downloading", .downloading), ("file", .file), ("inspect3D", .inspect3D), ("readFile", .readFile), ("sendAnswer", .sendAnswer),
    ]
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
                }
            }
        }
    }
}
#endif
