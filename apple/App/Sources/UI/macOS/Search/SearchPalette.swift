#if os(macOS)
import CueStore
import CueText
import SwiftUI

nonisolated private struct PaletteData: Sendable, Equatable {
    var matches: CardMatches
    var parents: [UUID: String]
    var subtasks: [UUID: TaskProgress]

    static func read(_ query: PaletteQuery, from store: isolated CueStore) throws -> PaletteData {
        let matches = try CardMatches.read(query, from: store)
        let cards = matches.entries.map(\.card), tasks = cards.filter(\.isTask)
        var parents: [UUID: String] = [:]
        for task in tasks {
            if let parent = task.parentID { parents[task.id] = try store.card(parent)?.title }
        }
        return PaletteData(matches: matches, parents: parents, subtasks: try store.subtaskProgress(of: tasks.map(\.id)))
    }
}

struct SearchPalette: View {
    enum Hit: Hashable {
        case session(String)
        case card(UUID)
    }

    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var query = PaletteQuery()
    @State private var data: PaletteData?
    @State private var selection: Hit?
    @State private var sessions: SessionSearchData?
    @FocusState private var focused: Bool

    private static let maxWidth: CGFloat = 840
    private static let height: CGFloat = 500
    private static let listWidth: CGFloat = 380
    private static let sideBySide: CGFloat = 680

    var body: some View {
        panel
            .onChange(of: active, initial: true) {
                focused = active
                if active, query.text.isEmpty { query.text = DebugHooks.preset.searchText }
            }
            // 关上时原样淡出（浮窗的退场，`Motion.fade`），淡完才清回空白：当场清的话结果先没了，幕还在淡
            .task(id: active) {
                guard !active, (try? await Task.sleep(for: .seconds(Motion.Fade.duration))) != nil else { return }
                if query != PaletteQuery() {
                    query = PaletteQuery()
                    data = nil
                    sessions = nil
                }
                selection = hits.first
            }
            .background { shortcuts }
            .observing(services.store, id: query.cards, into: $data, onError: workspace.fail) { [query] store in
                try PaletteData.read(query, from: store)
            }
            .onChange(of: hits) {
                if selection.map(hits.contains) != true { selection = hits.first }
            }
            .modifier(sessionObservation)
    }

    private var sessionObservation: SessionObservation {
        SessionObservation(key: SessionKey(text: query.text, project: query.project, limit: query.endedLimit, moment: services.speech), data: $sessions)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: Self.maxWidth, maxHeight: Self.height)
        .rowContainer(.rect(cornerRadius: Radius.card))
        .glass(in: .rect(cornerRadius: Radius.card))
        .opacity(data == nil || sessions == nil ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: Spacing.item) {
            Image(.search).foregroundStyle(palette.ink2).accessibilityHidden(true)
            TextField(String(localized: "搜索灵感、任务与会话"), text: $query.text, palette: palette)
                .textFieldStyle(.plain).font(Typography.searchField)
                .focused($focused)
                .onSubmit { if let selection { open(selection) } }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            Keycap(text: "esc")
        }
        .padding(.horizontal, Spacing.block).frame(height: 52)
    }

    @ViewBuilder private var content: some View {
        FilterBar(query: $query, total: query.listsCards ? data?.matches.total : nil)
             .padding(.horizontal, Spacing.inset).padding(.bottom, Spacing.item)
        Divider()
        ListWithPreview(listWidth: Self.listWidth, minimumWidth: Self.sideBySide) {
            results
            preview
        }
        .clipped()
        .environment(\.searchHighlight, query.text)
    }

    private func open(_ hit: Hit) {
        switch hit {
        case .session(let id): openSession(id)
        case .card(let id): if let entry = data?.matches.entries.first(where: { $0.id == id }) { open(entry.card) }
        }
    }

    private func openSession(_ sessionID: String) {
        workspace.searching = false
        workspace.show(.session(sessionID))
    }

    private var selected: CardEntry? {
        guard case .card(let id) = selection else { return nil }
        return data?.matches.entries.first { $0.id == id }
    }

    private var selectedSession: SessionState? {
        guard case .session(let id) = selection else { return nil }
        return sessionRows.first { $0.sessionID == id }
    }

    private var sessionRows: [SessionState] {
        guard query.listsSessions, let sessions else { return [] }
        let live = SessionState.inListOrder(sessions.live.map(workspace.withLiveState), state: \.self, cue: services.liveSessions.cue, at: services.speech)
        let all = live + sessions.ended
        return query.kind == .sessions ? all : Array(all.prefix(PaletteQuery.sessionPeek))
    }

    private var hits: [Hit] {
        sessionRows.map { .session($0.sessionID) } + (data?.matches.entries.map { .card($0.id) } ?? [])
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ResultsScroll(query: query) {
                LazyVStack(alignment: .leading, spacing: Spacing.hair) {
                    if query.isIdle {
                        SearchSuggestions(query: $query).padding(.top, Spacing.group)
                    } else if let data = data?.matches {
                        let rows = sessionRows
                        if rows.isEmpty, data.groups.isEmpty {
                            Text("没有找到灵感、任务或会话")
                                .font(Typography.secondary).foregroundStyle(palette.ink2)
                                .padding(.vertical, Spacing.block)
                        }
                        if !rows.isEmpty, let sessions {
                            let total = sessions.live.count + sessions.endedTotal
                            title { Text("会话"); Text("\(total)").foregroundStyle(palette.ink3) }
                            ForEach(rows, id: \.sessionID) { row($0, in: sessions).id(Hit.session($0.sessionID)) }
                            if query.kind != .sessions, total > rows.count {
                                more(Text("全部 \(total) 个会话")) { query.kind = .sessions }
                            } else if query.kind == .sessions, sessions.endedTotal > sessions.ended.count {
                                more(Text("显示更多（还有 \(sessions.endedTotal - sessions.ended.count) 个）")) { query.sessionPages += 1 }
                            }
                        }
                        ForEach(data.groups) { group in
                            let project = workspace.catalog?.project(group.id)
                            title {
                                ProjectGlyph(project: project, size: 11)
                                Text(project?.shownName ?? "")
                                Text("\(group.cards.count)").foregroundStyle(palette.ink3)
                            }
                            ForEach(group.cards) { entry in row(entry).id(Hit.card(entry.id)) }
                        }
                        if data.total > data.shown {
                            more(Text(CountCopy.more(data.total - data.shown))) { query.pages += 1 }
                        }
                    }
                }
                .padding(.vertical, Spacing.item).padding(.horizontal, Spacing.block)
            }
            .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
        }
    }

    private func title(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Spacing.glyph, content: content)
            .font(Typography.label).foregroundStyle(palette.ink2)
            .padding(.top, Spacing.group).padding(.bottom, Spacing.hair)
    }

    private func more(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) { title }
            .buttonStyle(PressStyle(.inline)).font(Typography.meta).foregroundStyle(palette.ink2)
            .padding(.vertical, Spacing.item)
    }

    private func row(_ session: SessionState, in sessions: SessionSearchData) -> some View {
        let hit = Hit.session(session.sessionID), isSelected = selection == hit
        return SessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: sessions.deliveries[session.sessionID],
            undelivered: sessions.undelivered[session.sessionID] ?? 0).equatable()
            .padding(.vertical, Spacing.item)
            .contentShape(.rect)
            .row(selected: isSelected)
            .onTapGesture { selection = hit }
            .simultaneousGesture(TapGesture(count: 2).onEnded { openSession(session.sessionID) })
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { openSession(session.sessionID) }
    }

    private func row(_ entry: CardEntry) -> some View {
        let card = entry.card, text = entry.text
        let isSelected = selection == .card(card.id)
        return HStack(spacing: Spacing.item) {
            Group {
                if card.isTask {
                    TaskRingView(status: card.status, done: false, size: 14)
                } else {
                    Image(text.attachments.isEmpty ? .document : .attachment).foregroundStyle(palette.ink2)
                }
            }
            .frame(width: 16)
            .accessibilityElement()
            .accessibilityLabel(Self.kindLabel(task: card.isTask, attachments: !text.attachments.isEmpty))
            Text(Highlight.matches(text.label, query.text)).font(Typography.body).lineLimit(1)
            Spacer()
            Text(DateLabel.short(card.modifiedAt)).font(Typography.meta).foregroundStyle(palette.ink2)
        }
        .frame(height: 34)
        .contentShape(.rect)
        .row(selected: isSelected)
        // 单击即选中、双击打开（同访达）：双击与单击并列识别——单击排在双击后面时要等过双击间隔才选中，点下去顿半拍
        .onTapGesture { selection = .card(card.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(card) })
    }

    @ViewBuilder private var preview: some View {
        if let entry = selected, let data {
            let card = entry.card, text = entry.text
            let rest = CueSummary.snippet(card.body, matching: query.text.split(whereSeparator: \.isWhitespace).map(String.init), whole: true)
            let project = workspace.catalog?.project(card.projectID)
            VStack(alignment: .leading, spacing: Spacing.group) {
                Text(text.label).font(Typography.previewTitle).foregroundStyle(palette.ink)
                Text(Dotted(project?.shownName, DateLabel.short(card.modifiedAt))).font(Typography.meta).foregroundStyle(palette.ink3)
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
                HStack(spacing: Spacing.group) {
                    Text("↩ 打开")
                    Text("⌘⇧C 复制")
                }
                .font(Typography.meta).foregroundStyle(palette.ink3).padding(.top, Spacing.tight)
            }
            .padding(Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .paper()
            .padding(Spacing.item)
            .frame(maxHeight: .infinity, alignment: .top)
        } else if let session = selectedSession {
            VStack(alignment: .leading, spacing: Spacing.group) {
                Text(SessionRename.title(of: session, request: nil, at: services.speech)).font(Typography.previewTitle).foregroundStyle(palette.ink)
                Text(Dotted(workspace.catalog?.project(session.projectID)?.shownName, DateLabel.short(session.stateSince)))
                    .font(Typography.meta).foregroundStyle(palette.ink3)
                if let prompt = session.pendingPrompt ?? session.lastPrompt {
                    Text(Highlight.matches(prompt, query.text)).font(Typography.body).lineSpacing(Typography.lineSpacing)
                        .foregroundStyle(palette.ink).lineLimit(8)
                }
                if let reply = SessionProgress.line(of: session) {
                    Text(reply).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(4)
                }
                Text("↩ 打开").font(Typography.meta).foregroundStyle(palette.ink3).padding(.top, Spacing.tight)
            }
            .padding(Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .paper()
            .padding(Spacing.item)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            Spacer().frame(maxWidth: .infinity)
        }
    }

    private static func kindLabel(task: Bool, attachments: Bool) -> LocalizedStringResource {
        switch (task, attachments) {
        case (true, false): "任务"
        case (true, true): "任务，含附件"
        case (false, false): "灵感"
        case (false, true): "灵感，含附件"
        }
    }

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
        let all = hits
        guard !all.isEmpty else { return }
        let index = selection.flatMap(all.firstIndex) ?? -step
        selection = all[min(max(index + step, 0), all.count - 1)]
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
    var project: UUID?
    var limit: Int
    var moment: Speech.Moment
}

private struct SessionObservation: ViewModifier {
    let key: SessionKey
    @Binding var data: SessionSearchData?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .observing(services.store, id: key, into: $data, onError: workspace.fail) { [key] store in
                try SessionSearchData.read(text: key.text, project: key.project, endedLimit: key.limit, at: key.moment, from: store)
            }
    }
}

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
