#if os(macOS)
import CueStore
import CueText
import SwiftUI

nonisolated private struct PaletteData: Sendable {
    var cards: [Card]
    var total: Int
    var projects: [Project]
    var lastSends: [UUID: LastSend]
    var targets: [SendTarget]
    /// 结果里的任务：上级的标题与下级（提示词、子任务）各自做完没有，预览里写它的进度。
    var parents: [UUID: String]
    var marks: [UUID: [ChildMark]]
}

/// ⌘K：两个范围。卡片——跨项目搜索，四个筛选（项目、含图片、发送目标、时间），结果按项目分组，右侧纸面预览；
/// ↑↓ 选择，↩ 打开，⌘↩ 发给 Agent（只有提示词），⌘⇧C 复制。会话——上面是在线的，下面是已结束的、按结束时间分段（分页，下一页只接在末尾），
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
    @State private var sessionPages = 1
    @State private var sessionSelection: String?
    @FocusState private var focused: Bool

    private static let maxWidth: CGFloat = 840
    private static let height: CGFloat = 500
    private static let listWidth: CGFloat = 380
    /// 列表 380 + 预览至少 300。
    private static let sideBySide: CGFloat = 680

    var body: some View {
        panel
            .onAppear {
                focused = active
                #if DEBUG
                if query.text.isEmpty { query.text = DebugScene.searchText }
                #endif
            }
            .onChange(of: query.text) {
                query.pages = 1
                sessionPages = 1
            }
            .background { if scope == .cards { shortcuts } }
            .observing(services.store, id: query, into: $data, onError: workspace.fail) { [query] store in
                let found = try store.search(query.store(), limit: PaletteQuery.pageSize * query.pages)
                var lastSends: [UUID: LastSend] = [:]
                for owner in Set(found.cards.map(\.projectID)) {
                    lastSends.merge(try store.lastSends(in: owner)) { current, _ in current }
                }
                var parents: [UUID: String] = [:], marks: [UUID: [ChildMark]] = [:]
                for task in found.cards where task.isTask {
                    marks[task.id] = try store.childMarks(of: task.id)[task.id]
                    if let parent = task.parentID { parents[task.id] = try store.card(parent)?.title }
                }
                return PaletteData(
                    cards: found.cards, total: found.totalCards, projects: try store.projects(),
                    lastSends: lastSends, targets: try store.sendTargets(), parents: parents, marks: marks)
            }
            #if DEBUG
            .onChange(of: data?.cards.map(\.id)) { PerfProbe.mark("search") }
            #endif
            .onChange(of: data?.cards.map(\.id)) {
                if let ids = data?.cards.map(\.id), selection.map(ids.contains) != true { selection = ids.first }
            }
            .modifier(sessionObservation)
    }

    /// 会话范围的数据（会话列表查询，分页；第一页很轻，卡片范围里也读着，切过去不闪空），选中项跟着结果走。
    private var sessionObservation: SessionObservation {
        SessionObservation(
            key: SessionKey(text: query.text, pages: sessionPages), data: $sessions,
            ids: sessionGroups.flatMap { $0.sessions.map(\.sessionID) }, selection: $sessionSelection)
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
        // 面大、字多：玻璃之上再垫一层接近实色的纸，背后的内容不透出来干扰阅读
        .background(palette.paper.opacity(palette.dark ? 0.9 : 0.86), in: .rect(cornerRadius: PanelStyle.radius, style: .continuous))
        .glass(in: .rect(cornerRadius: PanelStyle.radius, style: .continuous))
        // 第一份结果读到之前不显示：晚一帧出现，不先露一个空壳再长出内容
        .opacity((scope == .cards ? data == nil : sessions == nil) ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(scope == .cards ? "搜索灵感与任务" : "搜索会话", text: $query.text)
                .textFieldStyle(.plain).font(Typography.searchField)
                .focused($focused)
                .onSubmit {
                    switch scope {
                    case .cards: selected.map(open)
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
        FilterBar(query: $query, projects: data?.projects ?? [], targets: data?.targets ?? [], total: data?.total)
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
            selection: $sessionSelection, open: openSession) { sessionPages += 1 }
            .environment(\.searchHighlight, query.text)
    }

    private func openSession(_ sessionID: String) {
        workspace.searching = false
        workspace.show(.session(sessionID))
    }

    private var selected: Card? { data?.cards.first { $0.id == selection } }

    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）。
    private var sessionGroups: [SessionGroup] {
        SessionGroup.grouped(live: (sessions?.live ?? []).map(workspace.withLiveState), ended: sessions?.ended ?? [], now: .now)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let data {
                        if data.cards.isEmpty {
                            Text(query.text.isEmpty && !query.isFiltered ? "输入关键词，或用上面的筛选" : "没有找到灵感或任务")
                                .font(Typography.secondary).foregroundStyle(.secondary)
                                .padding(16)
                        }
                        ForEach(groups(data), id: \.owner) { group in
                            let project = data.projects.first { $0.id == group.owner }
                            HStack(spacing: 6) {
                                ProjectGlyph(project: project, size: 11)
                                Text(project?.name ?? "未分类")
                                Text("\(group.cards.count)").foregroundStyle(.tertiary)
                            }
                            .font(Typography.label).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                            ForEach(group.cards) { card in row(card).id(card.id) }
                        }
                        if data.total > data.cards.count {
                            Button("显示更多（还有 \(data.total - data.cards.count) 条）") { query.pages += 1 }
                                .buttonStyle(.plain).font(Typography.meta).foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
        }
    }

    private func row(_ card: Card) -> some View {
        let text = CardText(card.body)
        let isSelected = card.id == selection
        return HStack(spacing: 10) {
            // 任务用全 App 同一个任务圈打头，灵感是文档或图片
            Group {
                if card.isTask {
                    TaskRingView(status: card.status, ring: .plain, done: false, size: 14)
                } else {
                    Image(systemName: text.images.isEmpty ? "doc.text" : "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            .accessibilityElement()
            .accessibilityLabel((card.isTask ? "任务" : "灵感") + (text.images.isEmpty ? "" : "，含图片"))
            Text(Highlight.matches(text.label, query.text)).font(Typography.body).lineLimit(1)
            Spacer()
            Text(DateLabel.short(card.modifiedAt)).font(Typography.meta).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(isSelected ? palette.fill.opacity(3) : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(card) }
        .onTapGesture { selection = card.id }
    }

    /// 右侧预览：标题、项目与时间、任务的上级与进度、首图、标题之后的全文（搜着词时从命中处起、命中标色）；按内容高度收起，快捷键提示紧跟在下面。
    @ViewBuilder private var preview: some View {
        if let card = selected, let data {
            let text = CardText(card.body)
            // 搜着词时从第一处命中往前一点开始显示，命中不会落在下面看不到的地方
            let rest = CueSummary.snippet(card.body, matching: query.text.split(whereSeparator: \.isWhitespace).map(String.init), whole: true)
            let project = data.projects.first { $0.id == card.projectID }
            VStack(alignment: .leading, spacing: 10) {
                Text(text.label).font(Typography.previewTitle).foregroundStyle(palette.ink)
                HStack(spacing: 6) {
                    Text(Dotted(project?.name ?? "未分类", DateLabel.short(card.modifiedAt)))
                    if let name = data.lastSends[card.id]?.target.shownName { SentMark(target: name) }
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                if card.isTask, let facts = Self.taskFacts(parent: data.parents[card.id], marks: data.marks[card.id]) {
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
                    if CardMenu.handsToAgent(card) { Text("⌘↩ 发给 Agent") }
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

    /// 任务预览的一行："上级：修乱序 · 3 条提示词 · 1 已回复 · 子任务 1/2"；什么都没有时不写。
    private static func taskFacts(parent: String?, marks: [ChildMark]?) -> Dotted? {
        (Dotted(parent.map { "上级：\($0)" }) + (PromptTally(marks).text ?? Dotted()) + Dotted(TaskProgress.subtasks(in: marks).map(TaskCopy.progress))).nonEmpty
    }

    private var shortcuts: some View {
        ZStack {
            Button("发送") { if let card = selected { Task { await sendSelected(card) } } }
                .keyboardShortcut(.return, modifiers: .command)
            Button("复制") { if let card = selected { workspace.copy(Outgoing.text(of: card)) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    /// 只有提示词发给 Agent（本项目当前的会话）；灵感先挂到任务。
    private func sendSelected(_ card: Card) async {
        guard CardMenu.handsToAgent(card), let target = workspace.agentTarget(for: card.projectID) else { return }
        await workspace.send(Outgoing.text(of: card), to: target, card: card.id)
    }

    private func groups(_ data: PaletteData) -> [(owner: UUID?, cards: [Card])] {
        var order: [UUID?] = []
        var buckets: [UUID?: [Card]] = [:]
        for card in data.cards {
            if buckets[card.projectID] == nil { order.append(card.projectID) }
            buckets[card.projectID, default: []].append(card)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// 键盘选择按分组后的显示顺序移动。
    private func move(_ step: Int) {
        if scope == .sessions {
            let ids = sessionGroups.flatMap { $0.sessions.map(\.sessionID) }
            guard !ids.isEmpty else { return }
            let index = sessionSelection.flatMap(ids.firstIndex) ?? -step
            sessionSelection = ids[min(max(index + step, 0), ids.count - 1)]
            return
        }
        guard let data else { return }
        let ids = groups(data).flatMap { $0.cards.map(\.id) }
        guard !ids.isEmpty else { return }
        let index = selection.flatMap(ids.firstIndex) ?? -step
        selection = ids[min(max(index + step, 0), ids.count - 1)]
    }

    private func open(_ card: Card) {
        workspace.searching = false
        if card.projectID != workspace.currentProject {
            workspace.show(card.projectID.map(Workspace.Page.project) ?? .inbox)
        }
        workspace.openCard = card.id
    }
}

private struct SessionKey: Equatable {
    var text: String
    var pages: Int
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
                try SessionSearchData.read(text: key.text, pages: key.pages, from: store)
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

private struct FilterBar: View {
    @Binding var query: PaletteQuery
    let projects: [Project]
    let targets: [SendTarget]
    let total: Int?

    var body: some View {
        // 筛选在左、可横向滚动（窄面板里不被挤成省略号），结果数常驻右侧
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { chips }
            }
            if let total { Text(CountCopy.hits(total)).font(Typography.meta.monospacedDigit()).foregroundStyle(.secondary).fixedSize().layoutPriority(1) }
        }
    }

    @ViewBuilder private var chips: some View {
        FilterToken(name: "项目", value: projectLabel, on: query.project != nil) {
            Button("全部") { query.project = nil }
            Button("未分类") { query.project = .some(nil) }
            Divider()
            ForEach(projects) { project in Button(project.name) { query.project = project.id } }
        }
        Button { query.withImages.toggle() } label: {
            FilterCapsule(name: "含图片", value: nil, on: query.withImages)
        }
        .buttonStyle(PressStyle())
        FilterToken(name: "Agent", value: sentLabel, on: query.sent != .any) {
            Button("任意") { query.sent = .any }
            Divider()
            Button("没交给过 Agent") { query.sent = .never }
            Button("交给过 Agent") { query.sent = .sent(kind: .known(.piSession)) }
            if !targets.isEmpty {
                Divider()
                ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                    Button(target.name) { query.sent = .sent(kind: target.kind, name: target.name) }
                }
            }
        }
        FilterToken(name: "时间", value: query.period.label, on: query.period != .any) {
            ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
        }
    }

    private var projectLabel: String {
        switch query.project {
        case .none: "全部"
        case .some(.none): "未分类"
        case .some(.some(let id)): projects.first { $0.id == id }?.name ?? "全部"
        }
    }

    private var sentLabel: String {
        switch query.sent {
        case .any: "任意"
        case .never: "没交过"
        case .sent(_, .some(let name)): name
        case .sent(_, nil): "交过"
        }
    }
}

private struct FilterToken<Items: View>: View {
    let name: String
    let value: String
    let on: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu { items() } label: { FilterCapsule(name: name, value: value, on: on) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// 筛选胶囊：生效时填成实心。
private struct FilterCapsule: View {
    let name: String
    let value: String?
    let on: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(on ? AnyShapeStyle(palette.onAccent) : AnyShapeStyle(.secondary))
            if let value {
                Text(value).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6).accessibilityHidden(true)
            }
        }
        .font(Typography.meta)
        .foregroundStyle(on ? AnyShapeStyle(palette.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10).frame(height: 28)
        .background(on ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.fill.opacity(2)), in: .capsule)
        .contentShape(.capsule)
    }
}

#endif
