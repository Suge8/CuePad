#if os(macOS)
import CueStore
import SwiftUI

struct FilterBar: View {
    @Binding var query: PaletteQuery
    let total: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.group) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.item) {
                    SearchFilters(query: $query)
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(PressStyle())
            }
            if let total { Text(CountCopy.hits(total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2).fixedSize().layoutPriority(1) }
        }
    }
}
#endif
