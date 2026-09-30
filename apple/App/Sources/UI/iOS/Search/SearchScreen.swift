#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct SearchData: Sendable {
    var cards: [Card]
    var total: Int
    var projects: [Project]
    /// iOS 上可选的发送目标：只有本机能产生的（复制到剪贴板）。Pi 与应用投送是 Mac 专有。
    var targets: [SendTarget]
}

/// 搜索：跨项目，与 Mac 同样的筛选（项目、含图片、发送、时间），去掉 Mac 专有的发送目标。结果按项目分组。
struct SearchScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var query = PaletteQuery()
    @State private var data: SearchData?

    var body: some View {
        List {
            Section {
                FilterChips(query: $query, projects: data?.projects ?? [], targets: data?.targets ?? [])
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
            } footer: {
                if let data, !query.text.isEmpty || query.isFiltered { Text("\(data.total) 个结果") }
            }
            if let data {
                if data.cards.isEmpty, !query.text.isEmpty || query.isFiltered {
                    ContentUnavailableView.search(text: query.text)
                }
                ForEach(groups(data), id: \.owner) { group in
                    let project = data.projects.first { $0.id == group.owner }
                    Section {
                        ForEach(group.cards) { card in ResultRow(card: card, term: query.text) }
                    } header: {
                        HStack(spacing: 6) {
                            if let project { ProjectGlyph(project: project, size: 12) }
                            Text(project?.name ?? "未归档")
                        }
                    }
                }
                if data.total > data.cards.count {
                    Button("显示更多（还有 \(data.total - data.cards.count) 张）") { query.pages += 1 }
                }
            }
        }
        .deskBackground()
        .navigationTitle("搜索")
        .searchable(text: $query.text, prompt: "搜索卡片")
        .onChange(of: query.text) { query.pages = 1 }
        .onAppear {
            #if DEBUG
            if query.text.isEmpty { query.text = DebugScene.searchText }
            #endif
        }
        .observing(services.store, [.cards, .projects, .sendRecords], id: query, into: $data, onError: workspace.fail) { [query] store in
            let found = try store.search(query.store(), limit: PaletteQuery.pageSize * query.pages)
            return SearchData(
                cards: found.cards, total: found.totalCards, projects: try store.projects(),
                targets: try store.sendTargets().filter { $0.kind == .known(.clipboard) })
        }
    }

    private func groups(_ data: SearchData) -> [(owner: UUID?, cards: [Card])] {
        var order: [UUID?] = []
        var buckets: [UUID?: [Card]] = [:]
        for card in data.cards {
            if buckets[card.projectID] == nil { order.append(card.projectID) }
            buckets[card.projectID, default: []].append(card)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

private struct ResultRow: View {
    let card: Card
    let term: String
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let text = CardText(card.body)
        NavigationLink(value: Navigation.Route.card(card.id)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlight(text.title.nonEmpty ?? "空白卡片")).font(.body.weight(.medium)).lineLimit(1)
                    if !text.preview.isEmpty {
                        Text(highlight(text.preview)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(DateLabel.short(card.modifiedAt)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if let image = text.images.first { Thumbnail(hash: image, height: 48, radius: 6).frame(width: 64) }
            }
        }
        .zoomSource(card.id, in: zoom)
        .contextMenu { CardActions(card: card, isGoal: false) }
    }

    /// 搜索按空白拆成多个词、每个都要命中：每个词各自标出。
    private func highlight(_ text: String) -> AttributedString {
        term.split(whereSeparator: \.isWhitespace).reduce(AttributedString(text)) { result, word in
            Highlight.matches(text, String(word), base: result)
        }
    }
}

/// 筛选胶囊：项目、含图片、发送、时间；生效的填成实心。
private struct FilterChips: View {
    @Binding var query: PaletteQuery
    let projects: [Project]
    let targets: [SendTarget]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("全部") { query.project = nil }
                    Button("未归档") { query.project = .some(nil) }
                    Divider()
                    ForEach(projects) { project in Button(project.name) { query.project = project.id } }
                } label: { Chip(name: "项目", value: projectLabel, on: query.project != nil) }
                Button { query.withImages.toggle() } label: { Chip(name: "含图片", value: nil, on: query.withImages) }
                    .accessibilityAddTraits(query.withImages ? .isSelected : [])
                Menu {
                    Button("任意") { query.sent = .any }
                    Button("从未发送") { query.sent = .never }
                    Button("发送或复制过") { query.sent = .sent() }
                    if !targets.isEmpty {
                        Divider()
                        ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                            Button(target.name) { query.sent = .sent(kind: target.kind, name: target.name) }
                        }
                    }
                } label: { Chip(name: "发送", value: sentLabel, on: query.sent != .any) }
                Menu {
                    ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
                } label: { Chip(name: "时间", value: query.period.label, on: query.period != .any) }
            }
            .padding(.horizontal, 16)
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
        case .sent(_, .some(let name)): name
        case .sent(.known(.clipboard), nil): "剪贴板"
        case .sent: "发送过"
        }
    }
}

private struct Chip: View {
    let name: String
    let value: String?
    let on: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(on ? AnyShapeStyle(palette.onSolid) : AnyShapeStyle(.secondary))
            if let value {
                Text(value).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(0.6).accessibilityHidden(true)
            }
        }
        .font(.subheadline)
        .foregroundStyle(on ? AnyShapeStyle(palette.onSolid) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(on ? AnyShapeStyle(palette.solid) : AnyShapeStyle(palette.fill.opacity(2)), in: .capsule)
        .contentShape(.capsule)
    }
}
#endif
