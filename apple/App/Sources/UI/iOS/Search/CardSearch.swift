#if os(iOS)
import SwiftUI

/// 卡片搜索的结果（搜索页"灵感与任务"一栏）：筛选胶囊（前面是调用方给的 `leading`，右边写命中"N 条"）+ 按项目分组的卡片（多个词都要命中，最近修改在前）；
/// 没有搜索词与条件时列全部，库里还没有灵感与任务时是空态。
struct CardSearchResults<Leading: View>: View {
    @Binding var query: PaletteQuery
    @ViewBuilder let leading: Leading
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data: CardMatches?

    private var columns: [GridItem] {
        sizeClass == .regular ? [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)] : [GridItem(.flexible())]
    }

    var body: some View {
        ResultsScroll(query: query) {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ChipRow {
                        leading
                        SearchFilters(query: $query, targets: data?.targets ?? []) { name, value, on in
                            Chip(name: name, value: value, on: on)
                        }
                    }
                    if let data, !query.text.isEmpty || query.isFiltered {
                        Text(CountCopy.hits(data.total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                            .contentTransition(.numericText()).animation(Motion.fade, value: data.total)
                            .fixedSize().padding(.trailing, 16)
                    }
                }
                .padding(.horizontal, -16)
                if let data {
                    if data.total == 0 {
                        // 没有搜索词与条件时列的是全部：一条都没有就是库里还没有，不是没搜到
                        if !query.text.isEmpty || query.isFiltered {
                            EmptyState.noMatch(query.text).padding(.top, 24)
                        } else {
                            EmptyState(mascot: .search, title: "还没有灵感与任务", message: "记下的灵感、建的任务都能在这里搜到", waitsForSync: true)
                                .padding(.top, 24)
                        }
                    }
                    ForEach(data.groups) { group in
                        let project = workspace.catalog?.project(group.id)
                        HStack(spacing: 6) {
                            ProjectGlyph(project: project, size: 12)
                            SectionHeader(title: .verbatim(project?.shownName ?? ""), count: nil).padding(.horizontal, -4)
                        }
                        .padding(.top, 8)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.cards) { CardRow(entry: $0, highlight: query.text) }
                        }
                    }
                    if data.total > data.shown {
                        Button(CountCopy.more(data.total - data.shown)) { query.pages += 1 }
                            .frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        // 搜索框只报上屏的字（`SearchCapsule`）：拼音组字时不搜
        .observing(services.store, id: query, into: $data, onError: workspace.fail) { [query] store in
            try CardMatches.read(query, from: store)
        }
    }
}

/// 搜索的筛选胶囊：名称，生效时加上取值；有菜单的带下拉箭头。
private struct Chip: View {
    let name: String
    let value: String?
    let on: Bool

    var body: some View {
        FilterChip(on: on) {
            HStack(spacing: 4) {
                Text(name).opacity(on ? 0.7 : 1)
                if let value, on {
                    Text(value).fontWeight(.medium)
                }
                if value != nil {
                    Image(.expand).font(.caption2.weight(.bold)).opacity(0.5).accessibilityHidden(true)
                }
            }
        }
    }
}

/// 一排横向滑动的筛选胶囊。调用方给它让出页边距（`.padding(.horizontal, -16)`），它延伸到边缘、右侧 24pt 渐隐：
/// 看得出还能横着滑，而不是被页边距切断。
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }.padding(.horizontal, 16)
        }
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            }
        }
    }
}

/// 一颗筛选胶囊（搜索的筛选）：生效的是选中底（`selection`）与靛青字（选中一律用签名色），其余是纸底细边、墨色字。
struct FilterChip<Label: View>: View {
    let on: Bool
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        label
            .font(.subheadline)
            .fontWeight(on ? .semibold : nil)
            .foregroundStyle(on ? palette.signature : palette.ink)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(on ? palette.selection : palette.paper, in: .capsule)
            .overlay { if !on { Capsule().strokeBorder(palette.hair) } }
            .padding(.vertical, 4)
            .contentShape(.rect)
            .animation(Motion.fade, value: on)
    }
}
#endif
