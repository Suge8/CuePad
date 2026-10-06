#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// Agent 页：只回答"每个会话在做什么、现在到哪了、结果或卡点是什么"。"现在"是没结束的会话，按要你注意的先后排
/// （等你确认 → 出错 → 工作中 → 空闲）；"历史"是所有已结束的，按结束时间分段（今天、昨天……）、可搜，滑到底才读下一页。
/// 点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。顶上一排是搜索与新会话（iPhone 在导航栏里，
/// iPad 右侧面板没有导航栏、放在列表顶上），同步到不了 Mac 时同一排多一颗同步图标；列表顶上的项目胶囊按项目筛"现在"与"历史"。
struct AgentScreen: View {
    var inPanel = false
    /// 从项目页进来：先筛这个项目，在这里换的筛选不记下。
    var project: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var list: PiSessionList?
    @State private var query = ""
    @State private var limit = PiSessionList.pageSize
    /// 这一页上点过的筛选（`.some(nil)` 是全部）；没点过时用进来的项目或上次记下的。
    @State private var picked: UUID??

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 此刻的项目筛选：这一页上点过的，否则按 `Navigation.agentFilter`；项目进了回收站时是全部。
    private var filter: UUID? {
        guard let picked else { return navigation.agentFilter(entered: project, catalog: workspace.catalog) }
        return picked.flatMap { workspace.catalog?.project($0)?.id }
    }

    private func pick(_ id: UUID?) {
        picked = .some(id)
        navigation.chooseAgentFilter(id, entered: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if inPanel { panelHeader.padding(.bottom, 12) }
                if let list, let chips = chips(list) { chips.padding(.bottom, 16) }
                if let list { sessions(list) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        #if DEBUG
        .defaultScrollAnchor(DebugScene.scene == "agent" && DebugScene.defaults.integer(forKey: "CuePadHistory") > 0 && DebugScene.searchText.isEmpty ? .bottom : nil)
        #endif
        // 标题只作读屏、切换器与返回菜单里的名字：导航栏那一排是搜索框
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !inPanel {
                ToolbarItem(placement: .principal) { SearchCapsule(query: $query) }
                if !services.syncStatus.reachesMac {
                    ToolbarItem(placement: .primaryAction) { SyncBadge(status: services.syncStatus) }
                }
                ToolbarItem(placement: .primaryAction) { NewSessionButton(project: filter) }
            }
        }
        .refreshable { await services.syncNow() }
        .onChange(of: query) { limit = PiSessionList.pageSize }
        .onChange(of: filter) { limit = PiSessionList.pageSize }
        #if DEBUG
        .onAppear { if DebugScene.scene == "agent" { query = DebugScene.searchText } }
        #endif
        .observing(services.store, [.piSessionStates, .projects, .directoryBindings],
                   id: PiSessionList.Key(filter: .init(text: query, project: filter), limit: limit),
                   into: $list, onError: workspace.fail) { [query, filter, limit] store in
            try PiSessionList.read(text: query, project: filter, historyLimit: limit, from: store)
        }
    }

    /// 项目胶囊：全部 + 能筛的项目（项目目录的顺序）；一个项目都没有时不出现。
    private func chips(_ list: PiSessionList) -> ProjectChips? {
        let projects = (workspace.catalog?.projects ?? []).filter { list.projects.contains($0.id) || $0.id == filter }
        return projects.isEmpty ? nil : ProjectChips(projects: projects, selected: filter, pick: pick)
    }

    /// 会话列表。换搜索词或项目时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）；同一筛选下会话进出、换状态才有动画。
    private func sessions(_ list: PiSessionList) -> some View {
        // 间距逐项写：历史的行要首尾相接拼成一张纸
        LazyVStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                empty
            } else {
                if !list.now.isEmpty {
                    SectionTitle(text: "现在").padding(.bottom, 8)
                    rows(list.now, filtered: list.filter.project != nil).padding(.bottom, 24)
                }
                if !list.ended.isEmpty {
                    SectionTitle(text: "历史")
                    // 段内逐行懒加载：每行是 LazyVStack 的一个子项，滑到才画
                    ForEach(PiHistorySection.split(list.ended, date: \.state.stateSince, now: .now), id: \.section) { run in
                        Text(run.section.title).font(.footnote.weight(.medium)).foregroundStyle(palette.ink3)
                            .padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 6)
                        ForEach(Array(run.items.enumerated()), id: \.element.id) { index, item in
                            VStack(spacing: 0) {
                                if index > 0 { Divider().padding(.leading, 44) }
                                SessionRow(item: item, filtered: list.filter.project != nil)
                            }
                            .paperSlice(first: index == 0, last: index == run.items.count - 1, radius: 16)
                        }
                    }
                }
                if list.loaded < list.total {
                    // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                        .task(id: list.loaded) { limit = list.loaded + PiSessionList.pageSize }
                }
            }
        }
        .animation(Motion.quick, value: list.now.map(\.id))
        .animation(Motion.quick, value: list.now.map(\.state.state))
        .id(list.filter)
    }

    private func rows(_ items: [PiSessionListItem], filtered: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 44) }
                SessionRow(item: item, filtered: filtered)
            }
        }
        .paper(radius: 16)
    }

    @ViewBuilder private var empty: some View {
        if searching {
            ContentUnavailableView.search(text: query).padding(.top, 40)
        } else if let filter {
            ContentUnavailableView {
                Label("这个项目还没有 Pi 会话", systemImage: "waveform.path.ecg")
            } actions: {
                Button("新会话") { navigation.newSession = .init(project: filter) }.buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        } else {
            ContentUnavailableView {
                Label("还没有 Pi 会话", systemImage: "waveform.path.ecg")
            } description: {
                Text("在 Mac 上运行 pi，或在这里开一个新会话")
            } actions: {
                Button("新会话") { navigation.newSession = .init() }.buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        }
    }

    /// iPad 右侧面板没有导航栏：同一排放在列表顶上。
    private var panelHeader: some View {
        HStack(spacing: 8) {
            SearchCapsule(query: $query)
            if !services.syncStatus.reachesMac { SyncBadge(status: services.syncStatus) }
            NewSessionButton(project: filter)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).labelStyle(.iconOnly).controlSize(.large)
    }
}

/// 搜索框：玻璃胶囊，导航栏那一排与 iPad 面板顶上共用。
private struct SearchCapsule: View {
    @Binding var query: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField("搜会话、目录、说过的话", text: $query).submitLabel(.search)
            if !query.isEmpty {
                Button("清除", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette.ink3)
            }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44)
        .glass(in: .capsule)
    }
}

/// 新会话；筛着某个项目时新会话先选它。
private struct NewSessionButton: View {
    let project: UUID?
    @Environment(Navigation.self) private var navigation

    var body: some View {
        Button("新会话", systemImage: "plus") { navigation.newSession = .init(project: project) }
            .accessibilityHint("让 Mac 开一个 Pi 会话")
    }
}

/// 同步到不了 Mac 时的同步图标（平时不出现）：点开看哪里不通。
private struct SyncBadge: View {
    let status: SyncStatus
    @Environment(\.palette) private var palette
    @State private var open = false

    var body: some View {
        let summary = SyncSummary(status)
        Button(summary.title, systemImage: summary.symbol) { open = true }
            .tint(summary.color(palette))
            .popover(isPresented: $open) {
                SyncHint(status: status).padding(16).frame(idealWidth: 280).fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

/// 按项目筛的一排胶囊，横向滑动；选中的是墨色实心（同搜索的筛选胶囊）。
private struct ProjectChips: View {
    let projects: [Project]
    let selected: UUID?
    let pick: (UUID?) -> Void

    var body: some View {
        ChipRow {
            chip(nil) { Text("全部") }
            ForEach(projects) { project in
                chip(project.id) {
                    HStack(spacing: 6) {
                        ProjectGlyph(project: project, size: 13)
                        Text(project.name).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, -16)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func chip(_ id: UUID?, @ViewBuilder label: () -> some View) -> some View {
        let on = selected == id
        return Button { pick(id) } label: { FilterChip(on: on, label: label) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct SectionTitle: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Agent 页读到的会话："现在"是全部在线的（不多，不分页），按要你注意的先后；"历史"是已结束的前 `loaded` 条，
/// 从新到旧（分段见 `PiHistorySection`）。两部分用同一个搜索词与项目筛选。
nonisolated struct PiSessionList: Sendable, Equatable {
    static let pageSize = 40

    /// 搜索词与项目筛选：两部分共用。
    struct Filter: Hashable, Sendable {
        var text: String
        var project: UUID?
    }

    struct Key: Equatable {
        var filter: Filter
        var limit: Int
    }

    var filter: Filter
    var now: [PiSessionListItem]
    var ended: [PiSessionListItem]
    var total: Int
    /// 能按它筛的项目：在 Mac 上绑了代码目录的（会话按工作目录归入项目，没绑的不会有会话）。
    var projects: Set<UUID>

    var loaded: Int { ended.count }
    var isEmpty: Bool { now.isEmpty && total == 0 }

    static func read(text: String, project: UUID? = nil, historyLimit: Int, from store: isolated CueStore) throws -> PiSessionList {
        let live = try store.piSessionPage(PiSessionQuery(scope: .live, text: text, project: project, limit: .max)).items
        let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, project: project, limit: historyLimit))
        let order = Dictionary(uniqueKeysWithValues: PiSessionState.inListOrder(live.map(\.state)).enumerated().map { ($1.id, $0) })
        return PiSessionList(
            filter: Filter(text: text, project: project), now: live.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }, ended: ended.items, total: ended.total,
            projects: Set(try store.directoryBindings().map(\.projectID)))
    }
}

/// 一个会话三层：左边状态标；名字与时长；在哪（项目或文件夹；按项目筛着时不写） · 状态词（带色）（Mac 在后台托管的再写"后台"）；
/// 一句进度或结果（没有不占行）。已结束的整行更淡。
private struct SessionRow: View {
    let item: PiSessionListItem
    let filtered: Bool
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let session = item.state
        let shown = services.settings.shown(session)
        let place = filtered ? nil : PiPlace.name(of: session, project: item.project)
        Button { navigation.push(.session(session.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PiStateDot(shown: shown, size: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        PiElapsed(session: session)
                    }
                    HStack(spacing: 4) {
                        if let place { Text("\(place) ·").foregroundStyle(palette.ink3).lineLimit(1) }
                        Text(shown.label).fontWeight(shown.unread ? .semibold : .medium).foregroundStyle(shown.tint(palette))
                        if session.hosted, session.state != .known(.ended) { Text("· 后台").foregroundStyle(palette.ink3) }
                    }
                    .font(.subheadline)
                    if let progress = PiProgress.line(of: session) {
                        Text(progress).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(session.state == .known(.ended) ? 0.6 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、回复" : "看近况、回复")
    }
}

/// 同步到不了 Mac 时的一句提示（Agent 页同步图标点开、会话回复框上、新会话）：哪里不通；详情与处理在设置里。
struct SyncHint: View {
    let status: SyncStatus
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(status)
        Label("\(summary.title) · 看到的可能不是最新，也发不到 Mac", systemImage: summary.symbol)
            .font(.footnote).foregroundStyle(palette.ink3)
            .lineLimit(2)
    }
}
#endif

