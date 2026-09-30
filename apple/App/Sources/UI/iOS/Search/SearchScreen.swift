#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct SearchData: Sendable {
    var groups: [Group]
    var total: Int
    var shown: Int
    var projects: [Project]
    /// iOS 上可选的发送目标：只有本机能产生的（复制到剪贴板）。Pi 与应用投送是 Mac 专有。
    var targets: [SendTarget]

    /// 结果按项目分组，组按首次出现的顺序（即最相关的在前）。
    struct Group: Identifiable, Sendable {
        var project: Project?
        var cards: [CardEntry]
        var id: UUID? { project?.id }
    }

    static func grouped(_ cards: [Card], projects: [Project]) -> [Group] {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var order: [UUID?] = []
        var buckets: [UUID?: [CardEntry]] = [:]
        for card in cards {
            if buckets[card.projectID] == nil { order.append(card.projectID) }
            buckets[card.projectID, default: []].append(CardEntry(card))
        }
        return order.map { Group(project: $0.flatMap { byID[$0] }, cards: buckets[$0] ?? []) }
    }
}

/// 搜索：跨项目，多个词都要命中，可按项目、含图片、发送、时间筛选；结果按项目分组。
struct SearchScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var query = PaletteQuery()
    @State private var data: SearchData?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                FilterChips(query: $query, projects: data?.projects ?? [], targets: data?.targets ?? [])
                    .padding(.horizontal, -16)
                if let data {
                    if data.total == 0, !query.text.isEmpty || query.isFiltered {
                        ContentUnavailableView.search(text: query.text)
                    }
                    ForEach(data.groups) { group in
                        HStack(spacing: 6) {
                            ProjectGlyph(project: group.project, size: 12)
                            SectionHeader(title: group.project?.name ?? "未归档", count: nil).padding(.horizontal, -4)
                        }
                        .padding(.top, 8)
                        ForEach(group.cards) { CardRow(entry: $0, highlight: query.text) }
                    }
                    if data.total > data.shown {
                        Button("还有 \(data.total - data.shown) 张") { query.pages += 1 }
                            .frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(palette.desk)
        .navigationTitle("搜索")
        .navigationSubtitle(data.map { !query.text.isEmpty || query.isFiltered ? "\($0.total) 张" : "" } ?? "")
        .searchable(text: $query.text, prompt: "搜索卡片")
        .onChange(of: query.text) { query.pages = 1 }
        .onAppear {
            #if DEBUG
            if query.text.isEmpty { query.text = DebugScene.searchText }
            #endif
        }
        .observing(services.store, [.cards, .projects, .sendRecords], id: query, into: $data, onError: workspace.fail) { [query] store in
            let found = try store.search(query.store(), limit: PaletteQuery.pageSize * query.pages)
            let projects = try store.projects()
            return SearchData(
                groups: SearchData.grouped(found.cards, projects: projects), total: found.totalCards, shown: found.cards.count,
                projects: projects, targets: try store.sendTargets().filter { $0.kind == .known(.clipboard) })
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
            Text(name).opacity(on ? 0.7 : 1)
            if let value, on {
                Text(value).fontWeight(.medium)
            }
            if value != nil {
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(0.5).accessibilityHidden(true)
            }
        }
        .font(.subheadline)
        .foregroundStyle(on ? palette.onSolid : palette.ink)
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(on ? palette.solid : palette.paper, in: .capsule)
        .overlay { if !on { Capsule().strokeBorder(palette.hair) } }
        .contentShape(.capsule)
        .animation(Motion.quick, value: on)
    }
}
#endif
