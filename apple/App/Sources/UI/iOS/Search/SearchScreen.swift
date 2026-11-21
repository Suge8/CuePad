#if os(iOS)
import CueStore
import SwiftUI

struct SearchScreen: View {
    @State private var query = PaletteQuery()
    @State private var cards: CardMatches?
    @State private var sessions: SessionListData?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 页宽：导航栏中间那一格不会自己铺满，搜索框按页宽给定宽度（让出左边的返回、右边的筛选与两侧页边）。
    @State private var width: CGFloat = 0
    private static let maxField: CGFloat = 560
    static let prompt = String(localized: "搜索灵感、任务与会话")

    var body: some View {
        ResultsScroll(query: query) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.isFiltered { ActiveFilters(query: $query, total: query.kind == .sessions ? sessions?.count : cards?.total) }
                if query.isIdle {
                    SearchSuggestions(query: $query).padding(.top, Spacing.block)
                } else if let cards, !query.listsSessions || sessions != nil {
                    let list = query.listsSessions ? sessions : nil
                    if cards.total == 0, list?.isEmpty ?? true {
                        EmptyState.noMatch(query.text).padding(.top, Spacing.section)
                    } else {
                        if let list, !list.isEmpty { sessionSection(list) }
                        cardSections(cards)
                    }
                }
            }
            .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.section)
        }
        .scrollDismissesKeyboard(.immediately)
        .environment(\.searchHighlight, query.text)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .observing(services.store, id: query.cards, into: $cards, onError: workspace.fail) { [query] store in
            try CardMatches.read(query, from: store)
        }
        .observing(services.store, id: sessionKey, into: $sessions, onError: workspace.fail) { [key = sessionKey] store in
            try SessionListData.read(text: key.filter.text, project: key.filter.project, historyLimit: key.limit, at: key.moment, from: store)
        }
        .floatingHeader("搜索", center: {
            SearchCapsule(query: $query.text, focusRequests: workspace.searchFocusRequests).frame(width: fieldWidth)
        }) { SearchFilterMenu(query: $query) }
        .onAppear {
            if query.text.isEmpty { query.text = DebugHooks.preset.searchText }
            if DebugHooks.preset.searchListsSessions { query.kind = .sessions }
        }
    }

    private var sessionKey: SessionListData.Key {
        SessionListData.Key(filter: .init(text: query.text, project: query.project), limit: query.endedLimit, moment: services.speech)
    }

    private var fieldWidth: CGFloat {
        let sides = (FloatingHeaderLayout.margin + FloatingHeaderLayout.slot) * 2
        return min(Self.maxField, max(0, width - sides))
    }

    private var columns: [GridItem] {
        sizeClass == .regular ? [GridItem(.adaptive(minimum: 320), spacing: Spacing.block, alignment: .top)] : [GridItem(.flexible())]
    }

    // MARK: 会话

    @ViewBuilder private func sessionSection(_ list: SessionListData) -> some View {
        let active = list.pinned + list.now
        SectionHeader("会话", count: list.count).padding(.top, Spacing.block).padding(.bottom, Spacing.item)
        Group {
            if query.kind == .sessions {
                ForEach(active) { row($0, in: list) }
                ForEach(list.historyRuns, id: \.section) { run in
                    SectionHeader(Dotted(run.section.title), level: .group).padding(.top, Spacing.group).padding(.bottom, Spacing.tight)
                    ForEach(run.items) { row($0, in: list) }
                }
                if list.hasMore {
                    Spinner(.regular).frame(maxWidth: .infinity).padding(.vertical, Spacing.group)
                        .task(id: list.loaded) { query.sessionPages = list.loaded / SessionListData.pageSize + 1 }
                }
            } else {
                let shown = (active + list.ended).prefix(PaletteQuery.sessionPeek)
                ForEach(shown) { row($0, in: list) }
                if list.count > shown.count {
                    more(Text("全部 \(list.count) 个会话")) {
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { query.kind = .sessions }
                    }
                }
            }
        }
        .transaction(value: list.filter) { $0.animation = nil }
    }

    private func row(_ item: SessionListItem, in list: SessionListData) -> some View {
        let end = list.ends[item.id], ending = end?.inTransit == true
        return SessionListRow(item: item, showsPlace: list.showsPlace, end: end)
            .rowSwipes(SessionActions.swipes(item.state, task: item.task, ending: ending, in: workspace), clipped: false)
            .contextMenu { SessionActions(session: item.state, task: item.task, ending: ending) }
            .padding(.vertical, Spacing.tight)
    }

    // MARK: 灵感与任务

    @ViewBuilder private func cardSections(_ cards: CardMatches) -> some View {
        ForEach(cards.groups) { group in
            let project = workspace.catalog?.project(group.id)
            ProjectRunHeader(project: project, count: group.cards.count)
                .padding(.top, Spacing.block).padding(.bottom, Spacing.tight)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(group.cards) { CardRow(entry: $0, highlight: query.text) }
            }
        }
        if cards.total > cards.shown {
            more(Text(CountCopy.more(cards.total - cards.shown))) { query.pages += 1 }
        }
    }

    private func more(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.glyph) {
                title.font(Typography.secondary)
                Chevron(.expand)
            }
            .foregroundStyle(palette.ink2)
            .frame(maxWidth: .infinity, minHeight: RowMetrics.height, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }
}

private struct SearchFilterMenu: View {
    @Binding var query: PaletteQuery
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            Section("筛选") {
                Picker(selection: $query.kind) {
                    ForEach(PaletteQuery.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text("类别") }
                .pickerStyle(.menu)
                Picker(selection: $query.project) {
                    Label("全部项目", icon: .all).tag(UUID?.none)
                    ForEach(workspace.catalog?.projects ?? []) { project in
                        Label { Text(project.shownName) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                    }
                } label: { Text("项目") }
                .pickerStyle(.menu)
                Toggle("含附件", isOn: $query.withAttachments)
                Picker(selection: $query.period) {
                    ForEach(PaletteQuery.Period.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text("时间") }
                .pickerStyle(.menu)
            }
            .labelStyle(.titleAndIcon)
        } label: { Label("筛选", icon: .filter) }
        .accessibilityValue(query.isFiltered ? Text("已设条件") : Text(verbatim: ""))
    }
}

private struct ActiveFilters: View {
    @Binding var query: PaletteQuery
    let total: Int?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.item) {
                    if query.kind != .all { chip(query.kind.label) { query.kind = .all } }
                    if query.project != nil { chip(query.projectLabel(in: workspace.catalog?.projects ?? [])) { query.project = nil } }
                    if query.withAttachments { chip(String(localized: "含附件")) { query.withAttachments = false } }
                    if query.period != .any { chip(query.period.label) { query.period = .any } }
                }
            }
            if let total {
                Text(CountCopy.hits(total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                    .contentTransition(.numericText()).animation(Motion.fade, value: total).fixedSize()
            }
        }
        .padding(.top, Spacing.item)
    }

    private func chip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: Spacing.tight) {
                Text(title)
                Image(.close).font(Glyph.mark).foregroundStyle(palette.ink3)
            }
            .chip(on: true)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("撤掉条件：\(title)")
    }
}
#endif
