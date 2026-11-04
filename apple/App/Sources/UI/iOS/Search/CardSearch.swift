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
        sizeClass == .regular ? [GridItem(.adaptive(minimum: 320), spacing: Spacing.group, alignment: .top)] : [GridItem(.flexible())]
    }

    var body: some View {
        ResultsScroll(query: query) {
            LazyVStack(alignment: .leading, spacing: Spacing.group) {
                HStack(spacing: Spacing.item) {
                    ChipRow {
                        leading
                        SearchFilters(query: $query, targets: data?.targets ?? [])
                    }
                    if let data, !query.text.isEmpty || query.isFiltered {
                        Text(CountCopy.hits(data.total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                            .contentTransition(.numericText()).animation(Motion.fade, value: data.total)
                            .fixedSize().padding(.trailing, Spacing.block)
                    }
                }
                .padding(.horizontal, -Spacing.page)
                if let data {
                    if data.total == 0 {
                        // 没有搜索词与条件时列的是全部：一条都没有就是库里还没有，不是没搜到
                        if !query.text.isEmpty || query.isFiltered {
                            EmptyState.noMatch(query.text).padding(.top, Spacing.section)
                        } else {
                            EmptyState(mascot: .search, title: "还没有灵感与任务", message: "记下的灵感、建的任务都能在这里搜到", waitsForSync: true)
                                .padding(.top, Spacing.section)
                        }
                    }
                    ForEach(data.groups) { group in
                        let project = workspace.catalog?.project(group.id)
                        HStack(spacing: Spacing.glyph) {
                            ProjectGlyph(project: project, size: 12)
                            SectionHeader(Dotted(project?.shownName))
                        }
                        .padding(.top, Spacing.item)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.group) {
                            ForEach(group.cards) { CardRow(entry: $0, highlight: query.text) }
                        }
                    }
                    if data.total > data.shown {
                        Button(CountCopy.more(data.total - data.shown)) { query.pages += 1 }
                            .frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.section)
        }
        .scrollDismissesKeyboard(.immediately)
        // 搜索框只报上屏的字（`SearchCapsule`）：拼音组字时不搜
        .observing(services.store, id: query, into: $data, onError: workspace.fail) { [query] store in
            try CardMatches.read(query, from: store)
        }
    }
}

/// 一排横向滑动的筛选胶囊。调用方给它让出页边距（`.padding(.horizontal, -Spacing.page)`），它延伸到边缘、右侧 24pt 渐隐：
/// 看得出还能横着滑，而不是被页边距切断。
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.item) { content }.padding(.horizontal, Spacing.page)
        }
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            }
        }
    }
}
#endif
