#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// 两端同一份的结果，加上只有右侧预览要写的：最近发去哪里、任务的上级标题与子任务进度。
nonisolated private struct PaletteData: Sendable, Equatable {
    var matches: CardMatches
    var lastSends: [UUID: LastSend]
    var parents: [UUID: String]
    var subtasks: [UUID: TaskProgress]

    static func read(_ query: PaletteQuery, from store: isolated CueStore) throws -> PaletteData {
        let matches = try CardMatches.read(query, from: store)
        let cards = matches.entries.map(\.card), tasks = cards.filter(\.isTask)
        var lastSends: [UUID: LastSend] = [:]
        for group in matches.groups {
            lastSends.merge(try store.lastSends(in: group.id)) { current, _ in current }
        }
        var parents: [UUID: String] = [:]
        for task in tasks {
            if let parent = task.parentID { parents[task.id] = try store.card(parent)?.title }
        }
        return PaletteData(matches: matches, lastSends: lastSends, parents: parents, subtasks: try store.subtaskProgress(of: tasks.map(\.id)))
    }
}

/// ⌘K：两个范围。卡片——跨项目搜索，四个筛选（项目、含图片、发送目标、时间），结果按项目分组，右侧纸面预览；
/// ↑↓ 选择，↩ 打开，⌘⇧C 复制。会话——上面是在线的，下面是已结束的、按结束时间分段（分页，下一页只接在末尾），
/// 右侧是它的近况与回复。
struct SearchPalette: View {
    @Binding var scope: SearchScope
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var query = PaletteQuery()
    @State private var data: PaletteData?
    @State private var selection: UUID?
    @State private var sessions: SessionSearchData?
    @State private var sessionSelection: String?
    @FocusState private var focused: Bool

    private static let maxWidth: CGFloat = 840
    private static let height: CGFloat = 500
    private static let listWidth: CGFloat = 380
    /// 列表 380 + 预览至少 300。
    private static let sideBySide: CGFloat = 680

    var body: some View {
        panel
            // 常驻（`keptPanel`）：开合不重建，每次开时聚焦、从空的查询看起。收起时查询本来就是空的，结果留着：再开只是现出来，订阅回到前台后库变了再换；
            // 每次都清掉的话每次开都要当场重读、重建整列结果（真实库约多 150M 条指令）。查过别的才清掉，收着时先读好空查询的那份（`pagePrefetch`）
            .onChange(of: active, initial: true) {
                focused = active
                if active {
                    if query.text.isEmpty { query.text = DebugHooks.preset.searchText }
                    return
                }
                if query != PaletteQuery() {
                    query = PaletteQuery()
                    data = nil
                    sessions = nil
                }
                selection = cardIDs.first
                sessionSelection = sessionGroups.first?.sessions.first?.sessionID
            }
            .background { if scope == .cards { shortcuts } }
            .observing(services.store, id: query.cards, into: $data, onError: workspace.fail) { [query] store in
                try PaletteData.read(query, from: store)
            }
            .onChange(of: cardIDs) {
                if selection.map(cardIDs.contains) != true { selection = cardIDs.first }
            }
            .modifier(sessionObservation)
    }

    /// 会话范围的数据（会话列表查询，分页；第一页很轻，卡片范围里也读着，切过去不闪空），选中项跟着结果走。
    /// 收着时不读会话的实时状态：面板常驻，读了的话每个会话每变一次，收着看不见的它也整个重算、重排。
    private var sessionObservation: SessionObservation {
        SessionObservation(
            key: SessionKey(text: query.text, pages: query.sessionPages, moment: services.speech), data: $sessions,
            ids: active ? sessionGroups.flatMap { $0.sessions.map(\.sessionID) } : [], selection: $sessionSelection)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            switch scope {
            case .cards: cardsContent
            case .sessions: sessionsContent
            }
        }
        // 宽高都以详情区为上限（外层留边距）：同一窗口里面板尺寸固定，结果多少都不让它长高
        .frame(maxWidth: Self.maxWidth, maxHeight: Self.height)
        // 面大、字多：玻璃里垫九成实的底，背后的内容不透出来干扰阅读
        .rowContainer(.rect(cornerRadius: PanelStyle.radius, style: .continuous))
        .glass(in: .rect(cornerRadius: PanelStyle.radius, style: .continuous))
        // 第一份结果读到之前不显示：晚一帧出现，不先露一个空壳再长出内容
        .opacity((scope == .cards ? data == nil : sessions == nil) ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(.search).foregroundStyle(palette.ink2).accessibilityHidden(true)
            TextField(scope == .cards ? String(localized: "搜索灵感与任务") : String(localized: "搜索会话"), text: $query.text, palette: palette)
                .textFieldStyle(.plain).font(Typography.searchField)
                .focused($focused)
                .onSubmit {
                    switch scope {
                    case .cards: selected.map { open($0.card) }
                    case .sessions: sessionSelection.map(openSession)
                    }
                }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            Picker("范围", selection: $scope) {
                Text("灵感与任务").tag(SearchScope.cards)
                Text("会话").tag(SearchScope.sessions)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Keycap(text: "esc")
        }
        .padding(.horizontal, 18).frame(height: 52)
    }

    @ViewBuilder private var cardsContent: some View {
        FilterBar(query: $query, targets: data?.matches.targets ?? [], total: data?.matches.total)
            .padding(.horizontal, 14).padding(.bottom, 10)
        Divider()
        // 放得下就列表 + 预览并排，否则只留列表（最小窗口下详情区不到 500 宽）
        ListWithPreview(listWidth: Self.listWidth, minimumWidth: Self.sideBySide) {
            results
            preview
        }
        .clipped()
    }

    /// 会话范围：只有列表，方向键选、↩ 或点一下在内容区打开那个会话的整页（与侧栏、Agent 页同一处）。
    @ViewBuilder private var sessionsContent: some View {
        Divider()
        SessionResultList(
            groups: sessionGroups, deliveries: sessions?.deliveries ?? [:], undelivered: sessions?.undelivered ?? [:],
            more: (sessions?.endedTotal ?? 0) - (sessions?.ended.count ?? 0), isFiltered: !query.text.isEmpty,
            selection: $sessionSelection, open: openSession) { query.sessionPages += 1 }
            .environment(\.searchHighlight, query.text)
    }

    private func openSession(_ sessionID: String) {
        workspace.searching = false
        workspace.show(.session(sessionID))
    }

    private var selected: CardEntry? { data?.matches.entries.first { $0.id == selection } }

    /// 结果从上到下的顺序：方向键照它走，结果一变就选中第一张（原来选的还在就不动）。
    private var cardIDs: [UUID] { data?.matches.entries.map(\.id) ?? [] }

    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）。
    private var sessionGroups: [SessionGroup] {
        SessionGroup.grouped(live: (sessions?.live ?? []).map(workspace.withLiveState), ended: sessions?.ended ?? [], cue: services.liveSessions.cue, now: .now, at: services.speech)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ResultsScroll(query: query) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let data = data?.matches {
                        if data.groups.isEmpty {
                            Text(query.text.isEmpty && !query.isFiltered ? "输入关键词，或用上面的筛选" : "没有找到灵感或任务")
                                .font(Typography.secondary).foregroundStyle(palette.ink2)
                                .padding(.vertical, 16)
                        }
                        ForEach(data.groups) { group in
                            let project = workspace.catalog?.project(group.id)
                            HStack(spacing: 6) {
                                ProjectGlyph(project: project, size: 11)
                                Text(project?.shownName ?? "")
                                Text("\(group.cards.count)").foregroundStyle(palette.ink3)
                            }
                            .font(Typography.label).foregroundStyle(palette.ink2)
                            .padding(.top, 10).padding(.bottom, 2)
                            ForEach(group.cards) { entry in row(entry).id(entry.id) }
                        }
                        if data.total > data.shown {
                            Button(CountCopy.more(data.total - data.shown)) { query.pages += 1 }
                                .buttonStyle(PressStyle(.inline)).font(Typography.meta).foregroundStyle(palette.ink2)
                                .padding(.vertical, 10)
                        }
                    }
                }
                // 行的底向两边让出一截，留在滚动区里
                .padding(.vertical, 8).padding(.horizontal, 18)
            }
            .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
        }
    }

    private func row(_ entry: CardEntry) -> some View {
        let card = entry.card, text = entry.text
        let isSelected = card.id == selection
        return HStack(spacing: 10) {
            Group {
                if card.isTask {
                    TaskRingView(status: card.status, done: false, size: 14)
                } else {
                    Image(text.images.isEmpty ? .document : .photo).foregroundStyle(palette.ink2)
                }
            }
            .frame(width: 16)
            .accessibilityElement()
            .accessibilityLabel(Self.kindLabel(task: card.isTask, images: !text.images.isEmpty))
            Text(Highlight.matches(text.label, query.text)).font(Typography.body).lineLimit(1)
            Spacer()
            Text(DateLabel.short(card.modifiedAt)).font(Typography.meta).foregroundStyle(palette.ink2)
        }
        .frame(height: 34)
        .contentShape(.rect)
        .row(selected: isSelected)
        // 单击即选中、双击打开（同访达）：双击与单击并列识别——单击排在双击后面时要等过双击间隔才选中，点下去顿半拍
        .onTapGesture { selection = card.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(card) })
    }

    /// 右侧预览：标题、项目与时间、任务的上级与进度、首图、标题之后的全文（搜着词时从命中处起、命中标色）；按内容高度收起，快捷键提示紧跟在下面。
    @ViewBuilder private var preview: some View {
        if let entry = selected, let data {
            let card = entry.card, text = entry.text
            // 搜着词时从第一处命中往前一点开始显示，命中不会落在下面看不到的地方
            let rest = CueSummary.snippet(card.body, matching: query.text.split(whereSeparator: \.isWhitespace).map(String.init), whole: true)
            let project = workspace.catalog?.project(card.projectID)
            VStack(alignment: .leading, spacing: 10) {
                Text(text.label).font(Typography.previewTitle).foregroundStyle(palette.ink)
                HStack(spacing: 6) {
                    Text(Dotted(project?.shownName, DateLabel.short(card.modifiedAt)))
                    if let name = data.lastSends[card.id]?.target.shownName { SentMark(target: name) }
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                if card.isTask, let facts = Self.taskFacts(parent: data.parents[card.id], subtasks: data.subtasks[card.id]) {
                    Text(facts).font(Typography.meta).foregroundStyle(palette.ink2)
                }
                if let image = text.images.first { Thumbnail(hash: image, height: 150) }
                if !rest.isEmpty {
                    let body = Text(Highlight.matches(rest, query.text, base: VariableText.styled(rest, palette)))
                        .font(Typography.body).lineSpacing(Typography.lineSpacing).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .vertical) {
                        body.fixedSize(horizontal: false, vertical: true)
                        ScrollView { body }
                    }
                }
                HStack(spacing: 12) {
                    Text("↩ 打开")
                    Text("⌘⇧C 复制")
                }
                .font(Typography.meta).foregroundStyle(palette.ink3).padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .paper(radius: 16)
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            Spacer().frame(maxWidth: .infinity)
        }
    }

    private static func kindLabel(task: Bool, images: Bool) -> LocalizedStringResource {
        switch (task, images) {
        case (true, false): "任务"
        case (true, true): "任务，含图片"
        case (false, false): "灵感"
        case (false, true): "灵感，含图片"
        }
    }

    /// 任务预览的一行："上级：修乱序 · 子任务 1/2"；什么都没有时不写。
    private static func taskFacts(parent: String?, subtasks: TaskProgress?) -> Dotted? {
        Dotted(parent.map { String(localized: "上级：\($0)") }, subtasks.map(TaskCopy.progress)).nonEmpty
    }

    private var shortcuts: some View {
        ZStack {
            Button("复制") { if let entry = selected { workspace.copy(Outgoing.text(of: entry.card)) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func move(_ step: Int) {
        if scope == .sessions {
            let ids = sessionGroups.flatMap { $0.sessions.map(\.sessionID) }
            guard !ids.isEmpty else { return }
            let index = sessionSelection.flatMap(ids.firstIndex) ?? -step
            sessionSelection = ids[min(max(index + step, 0), ids.count - 1)]
            return
        }
        let ids = cardIDs
        guard !ids.isEmpty else { return }
        let index = selection.flatMap(ids.firstIndex) ?? -step
        selection = ids[min(max(index + step, 0), ids.count - 1)]
    }

    private func open(_ card: Card) {
        workspace.searching = false
        if card.projectID != workspace.currentProject {
            workspace.show(.project(card.projectID))
        }
        workspace.open(card)
    }
}

private struct SessionKey: Equatable {
    var text: String
    var pages: Int
    var moment: Speech.Moment
}

private struct SessionObservation: ViewModifier {
    let key: SessionKey
    @Binding var data: SessionSearchData?
    let ids: [String]
    @Binding var selection: String?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .observing(services.store, id: key, into: $data, onError: workspace.fail) { [key] store in
                try SessionSearchData.read(text: key.text, pages: key.pages, at: key.moment, from: store)
            }
            .onChange(of: ids) { if selection.map(ids.contains) != true { selection = ids.first } }
    }
}

/// 搜索面板的内容区：宽度够（minimumWidth）就列表定宽在左、预览占余下；不够就只摆列表，预览不占位置。
/// 纯排版，宽高都取拿到的尺寸，不按内容长高。
private struct ListWithPreview: Layout {
    let listWidth: CGFloat
    let minimumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: minimumWidth, height: 300))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard subviews.count == 2 else { return }
        let wide = bounds.width >= minimumWidth
        let list = wide ? listWidth : bounds.width
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: list, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + list, y: bounds.minY),
            proposal: ProposedViewSize(width: wide ? bounds.width - list : 0, height: bounds.height))
    }
}

#endif
