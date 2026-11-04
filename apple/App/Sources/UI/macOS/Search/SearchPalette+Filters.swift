#if os(macOS)
import CueStore
import SwiftUI

struct FilterBar: View {
    @Binding var query: PaletteQuery
    let targets: [SendTarget]
    let total: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        // 筛选在左、可横向滚动（窄面板里不被挤成省略号），结果数常驻右侧
        HStack(spacing: Spacing.group) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    SearchFilters(query: $query, targets: targets)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(PressStyle())
            }
            if let total { Text(CountCopy.hits(total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2).fixedSize().layoutPriority(1) }
        }
    }
}
#endif
