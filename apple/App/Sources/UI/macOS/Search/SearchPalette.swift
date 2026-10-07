#if os(macOS)
import CueStore
import SwiftUI

nonisolated private struct PaletteData: Sendable {
    var cards: [Card]
    var total: Int
    var projects: [Project]
    var lastSends: [UUID: LastSend]
    var targets: [SendTarget]
}

/// ⌘K：两个范围。卡片——跨项目搜索，四个筛选（项目、含图片、发送目标、时间），结果按项目分组，右侧纸面预览；
/// ↑↓ 选择，↩ 打开，⌘↩ 发送，⌘⇧C 复制。会话——上面是在线的，下面是已结束的、按结束时间分段（分页，下一页只接在末尾），
/// 右侧是它的近况与回复。
struct SearchPalette: View {
    @Binding var scope: SearchScope
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
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
                focused = true
                #if DEBUG
                if query.text.isEmpty { query.text = DebugScene.searchText }
                if let session = DebugScene.sessionToOpen {
                    scope = .sessions
                    sessionSelection = session
                }
                #endif
            }
            .onChange(of: query.text) {
                query.pages = 1
                sessionPages = 1
            }
            .background { if scope == .cards { shortcuts } }
            .observing(services.store, [.cards, .projects, .sendRecords], id: query, into: $data, onError: workspace.fail) { [query] store in
                let found = try store.search(query.store(), limit: PaletteQuery.pageSize * query.pages)
                var lastSends: [UUID: LastSend] = [:]
                for owner in Set(found.cards.map(\.projectID)) {
                    lastSends.merge(try store.lastSends(in: owner)) { current, _ in current }
                }
                return PaletteData(
                    cards: found.cards, total: found.totalCards, projects: try store.projects(),
                    lastSends: lastSends, targets: try store.sendTargets())
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
        .background(palette.paper.opacity(palette.dark ? 0.9 : 0.86), in: .rect(cornerRadius: 26))
        .glass(in: .rect(cornerRadius: 26))
        // 第一份结果读到之前不显示：晚一帧出现，不先露一个空壳再长出内容
        .opacity((scope == .cards ? data == nil : sessions == nil) ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(scope == .cards ? "搜索卡片" : "搜索会话", text: $query.text)
                .textFieldStyle(.plain).font(.system(size: 18))
                .focused($focused)
                .onSubmit { if scope == .cards { selected.map(open) } }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            Picker("范围", selection: $scope) {
                Text("卡片").tag(SearchScope.cards)
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

    @ViewBuilder private var sessionsContent: some View {
        Divider()
        ListWithPreview(listWidth: Self.listWidth, minimumWidth: Self.sideBySide) {
            SessionResultList(
                groups: sessionGroups, deliveries: sessions?.deliveries ?? [:],
                more: (sessions?.endedTotal ?? 0) - (sessions?.ended.count ?? 0), isFiltered: !query.text.isEmpty,
                selection: $sessionSelection) { sessionPages += 1 }
            sessionPreview
        }
        .clipped()
    }

    private var selected: Card? { data?.cards.first { $0.id == selection } }

    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）。
    private var sessionGroups: [SessionGroup] {
        SessionGroup.grouped(live: (sessions?.live ?? []).map(workspace.withLiveState), ended: sessions?.ended ?? [], now: .now)
    }

    @ViewBuilder private var sessionPreview: some View {
        if let sessionSelection {
            PiSessionDetail(sessionID: sessionSelection, embedded: true)
                .background(palette.desk, in: .rect(cornerRadius: 16))
                .padding(10)
        } else {
            Spacer().frame(maxWidth: .infinity)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let data {
                        if data.cards.isEmpty {
                            Text(query.text.isEmpty && !query.isFiltered ? "输入关键词，或用上面的筛选" : "没有找到卡片")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .padding(16)
                        }
                        ForEach(groups(data), id: \.owner) { group in
                            let project = data.projects.first { $0.id == group.owner }
                            HStack(spacing: 6) {
                                ProjectGlyph(project: project, size: 11)
                                Text(project?.name ?? "未归档")
                                Text("\(group.cards.count)").foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                            ForEach(group.cards) { card in row(card).id(card.id) }
                        }
                        if data.total > data.cards.count {
                            Button("显示更多（还有 \(data.total - data.cards.count) 张）") { query.pages += 1 }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
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
            Image(systemName: text.images.isEmpty ? "doc.text" : "photo").frame(width: 16).foregroundStyle(.secondary)
                .accessibilityLabel(text.images.isEmpty ? "卡片" : "含图片的卡片")
            Text(Highlight.matches(text.title.isEmpty ? "空白卡片" : text.title, query.text)).font(.system(size: 13.5)).lineLimit(1)
            Spacer()
            Text(DateLabel.short(card.modifiedAt)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(isSelected ? palette.fill.opacity(3) : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(card) }
        .onTapGesture { selection = card.id }
    }

    @ViewBuilder private var preview: some View {
        if let card = selected, let data {
            let text = CardText(card.body)
            let project = data.projects.first { $0.id == card.projectID }
            VStack(alignment: .leading, spacing: 10) {
                Text(text.title.isEmpty ? "空白卡片" : text.title).font(.system(size: 17, weight: .bold)).foregroundStyle(palette.ink)
                HStack(spacing: 6) {
                    Text("\(project?.name ?? "未归档") · \(DateLabel.short(card.modifiedAt))")
                    if let send = data.lastSends[card.id] { SentMark(target: send.target.name) }
                }
                .font(.system(size: 11)).foregroundStyle(palette.ink3)
                if let image = text.images.first { Thumbnail(hash: image, height: 150) }
                ScrollView {
                    Text(Highlight.matches(text.preview, query.text, base: VariableText.styled(text.preview, palette)))
                        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) { Text("↩ 打开"); Text("⌘↩ 发送"); Text("⌘⇧C 复制") }
                .font(.system(size: 11)).foregroundStyle(palette.ink3)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .paper(radius: 16)
            .padding(10)
        } else {
            Spacer().frame(maxWidth: .infinity)
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("发送") { if let card = selected { Task { await sendSelected(card) } } }
                .keyboardShortcut(.return, modifiers: .command)
            Button("复制") { if let card = selected { Task { await workspace.send(Outgoing.text(of: card), via: .clipboard, card: card.id) } } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func sendSelected(_ card: Card) async {
        await workspace.send(Outgoing.text(of: card), via: workspace.effectiveChoice(for: card.projectID), card: card.id)
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
        workspace.overlay = nil
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
            .observing(services.store, [.piSessionStates, .deliveryRequests, .projects], id: key, into: $data, onError: workspace.fail) { [key] store in
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
            if let total { Text("\(total) 个结果").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize().layoutPriority(1) }
        }
    }

    @ViewBuilder private var chips: some View {
        FilterToken(name: "项目", value: projectLabel, on: query.project != nil) {
            Button("全部") { query.project = nil }
            Button("未归档") { query.project = .some(nil) }
            Divider()
            ForEach(projects) { project in Button(project.name) { query.project = project.id } }
        }
        Button { query.withImages.toggle() } label: {
            FilterCapsule(name: "含图片", value: nil, on: query.withImages)
        }
        .buttonStyle(PressStyle())
        FilterToken(name: "发送目标", value: sentLabel, on: query.sent != .any) {
            Button("任意") { query.sent = .any }
            Divider()
            Button("从未发送") { query.sent = .never }
            Divider()
            Button("Pi 会话") { query.sent = .sent(kind: .known(.piSession)) }
            Button("应用") { query.sent = .sent(kind: .known(.app)) }
            Button("剪贴板") { query.sent = .sent(kind: .known(.clipboard)) }
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
        case .some(.none): "未归档"
        case .some(.some(let id)): projects.first { $0.id == id }?.name ?? "全部"
        }
    }

    private var sentLabel: String {
        switch query.sent {
        case .any: "任意"
        case .never: "从未发送"
        case .sent(let kind, .some(let name)): kind == .known(.piSession) ? "Pi · \(name)" : name
        case .sent(.known(.piSession), nil): "Pi 会话"
        case .sent(.known(.app), nil): "应用"
        case .sent(.known(.clipboard), nil): "剪贴板"
        case .sent(.unknown(let raw), nil): raw
        case .sent(nil, nil): "发送过"
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
        .font(.system(size: 12))
        .foregroundStyle(on ? AnyShapeStyle(palette.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10).frame(height: 26)
        .background(on ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.fill.opacity(2)), in: .capsule)
        .contentShape(.capsule)
    }
}

#endif
