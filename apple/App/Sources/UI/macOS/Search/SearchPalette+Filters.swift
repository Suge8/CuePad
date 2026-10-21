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
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    SearchFilters(query: $query, targets: targets) { name, value, on in
                        FilterCapsule(name: name, value: value, on: on)
                    }
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(PressStyle())
            }
            if let total { Text(CountCopy.hits(total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2).fixedSize().layoutPriority(1) }
        }
    }
}

/// 选中的是选中底（`selection`）与靛青字，同手机的 `FilterChip`。
private struct FilterCapsule: View {
    let name: String
    let value: String?
    let on: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(on ? palette.signature : palette.ink2)
            if let value {
                Text(value).fontWeight(.medium)
                Image(.expand).font(.system(size: 8, weight: .bold)).opacity(0.6).accessibilityHidden(true)
            }
        }
        .font(Typography.meta)
        .foregroundStyle(on ? palette.signature : palette.ink)
        .padding(.horizontal, 10).frame(height: 28)
        .background(on ? palette.selection : palette.fill, in: .capsule)
        .contentShape(.capsule)
    }
}
#endif
