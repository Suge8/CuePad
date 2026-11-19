#if os(iOS)
import CueStore
import SwiftUI

/// 一个搜索词出一张表：会话一节在上（先列几个，点开才列全），灵感与任务按项目排在下面。没打字也没设条件时只列手上的会话与最近改的几条，
/// 不把全库倒出来（规则在 `PaletteQuery`）。结果直接落在桌面上，不一条一张纸。
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
                if query.isFiltered { ActiveFilters(query: $query, total: cards?.total) }
                // 两份都读到了再排：先到的那份单独排一下，另一份到时整页往下一跳
                if let cards, !query.listsSessions || sessions != nil {
                    let list = query.listsSessions ? sessions : nil
                    if cards.total == 0, list?.isEmpty ?? true {
                        vacant
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
        // 搜索框只报上屏的字（`SearchCapsule`）：拼音组字时不搜
        .observing(services.store, id: query.cards, into: $cards, onError: workspace.fail) { [query] store in
            try CardMatches.read(query, from: store)
        }
        .observing(services.store, id: sessionKey, into: $sessions, onError: workspace.fail) { [key = sessionKey] store in
            try SessionListData.read(text: key.filter.text, project: key.filter.project, historyLimit: key.limit, at: key.moment, from: store)
        }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("搜索", center: {
            SearchCapsule(query: $query.text, focusRequests: workspace.searchFocusRequests).frame(width: fieldWidth)
        }) { SearchFilterMenu(query: $query) }
        .onAppear {
            if query.text.isEmpty { query.text = DebugHooks.preset.searchText }
            if DebugHooks.preset.searchListsSessions { query.sessionsExpanded = true }
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

    @ViewBuilder private var vacant: some View {
        // 闲着时列的是手上的与最近的：一条都没有就是库里还没有，不是没搜到
        if query.isIdle {
            EmptyState(mascot: .search, title: "还没有灵感与任务", message: "记下的灵感、建的任务都能在这里搜到", waitsForSync: true)
                .padding(.top, Spacing.section)
        } else {
            EmptyState.noMatch(query.text).padding(.top, Spacing.section)
        }
    }

    // MARK: 会话

    @ViewBuilder private func sessionSection(_ list: SessionListData) -> some View {
        let active = list.pinned + list.now
        SectionHeader("会话", count: list.count).padding(.top, Spacing.block).padding(.bottom, Spacing.item)
        Group {
            if query.sessionsExpanded {
                ForEach(active) { row($0, in: list) }
                ForEach(list.historyRuns, id: \.section) { run in
                    SectionHeader(Dotted(run.section.title), level: .group).padding(.top, Spacing.group).padding(.bottom, Spacing.tight)
                    ForEach(run.items) { row($0, in: list) }
                }
                if list.hasMore {
                    // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                    Spinner(.regular).frame(maxWidth: .infinity).padding(.vertical, Spacing.group)
                        .task(id: list.loaded) { query.sessionPages = list.loaded / SessionListData.pageSize + 1 }
                }
            } else {
                let shown = (active + list.ended).prefix(query.sessionPeek)
                ForEach(shown) { row($0, in: list) }
                if list.count > shown.count {
                    more(Text("全部 \(list.count) 个会话")) {
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { query.sessionsExpanded = true }
                    }
                }
            }
        }
        // 换搜索词时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）
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
        if query.isIdle {
            if !cards.entries.isEmpty {
                SectionHeader("最近").padding(.top, Spacing.block).padding(.bottom, Spacing.tight)
                grid(cards.entries, placed: true)
            }
        } else {
            ForEach(cards.groups) { group in
                let project = workspace.catalog?.project(group.id)
                HStack(spacing: Spacing.glyph) {
                    ProjectGlyph(project: project, size: 12)
                    SectionHeader(Dotted(project?.shownName), count: group.cards.count)
                }
                .padding(.top, Spacing.block).padding(.bottom, Spacing.tight)
                grid(group.cards, placed: false)
            }
            if cards.total > cards.shown {
                more(Text(CountCopy.more(cards.total - cards.shown))) { query.pages += 1 }
            }
        }
    }

    /// `placed`：行里标出所属项目（没按项目分组时）。
    private func grid(_ entries: [CardEntry], placed: Bool) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                CardRow(entry: entry, project: placed ? .some(workspace.catalog?.project(entry.card.projectID)) : nil, highlight: query.text, flat: true)
            }
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

/// 页头右边那一颗：条件收在菜单里，不在结果上面占一排。设了的条件在结果顶上各一颗（`ActiveFilters`），看得见、点一下就撤。
private struct SearchFilterMenu: View {
    @Binding var query: PaletteQuery
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            Section("筛选") {
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
