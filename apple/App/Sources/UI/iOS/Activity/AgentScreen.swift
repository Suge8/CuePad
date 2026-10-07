#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// Agent 页：只回答"每个会话在做什么、现在到哪了、结果或卡点是什么"。"现在"是没结束的会话，按要你注意的先后排
/// （等你确认 → 出错 → 工作中 → 空闲）；"历史"是所有已结束的，按结束时间分段（今天、昨天……）、可搜，滑到底才读下一页。
/// 点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。顶上一排是搜索与新会话（`SearchRow`），同步到不了 Mac 时
/// 同一排多一颗同步图标；从项目页"全部 N 个会话"推入的那一页用推入页的悬浮顶栏（项目名、会话数、新会话），搜索在它下面一排。
/// 列表顶上的项目胶囊按项目筛"现在"与"历史"。在线会话长按或左滑可结束（确认后发给它所在的 Mac，对话留着）。
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
    @FocusState private var searchFocused: Bool
    /// 正在结束、没能结束的会话（按记录 id）；结束成功后它进了"历史"，这里清掉。
    @State private var ending: [UUID: Ending] = [:]
    @State private var confirmingEnd: PiSessionState?

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
        List {
            if let list {
                if let chips = chips(list) {
                    chips.listRowInsets(.init())
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                sessions(list)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(16)
        // 与书架同一页边距；顶上不留分组列表默认的空白，项目胶囊紧接在搜索那一排下面
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .confirmationDialog("结束这个会话？", isPresented: Binding { confirmingEnd != nil } set: { if !$0 { confirmingEnd = nil } },
                            titleVisibility: .visible, presenting: confirmingEnd) { session in
            Button("结束会话", role: .destructive) { end(session) }
        } message: { _ in
            Text("对话会保留，再给它发消息会在后台恢复")
        }
        #if DEBUG
        .defaultScrollAnchor(DebugScene.scene == "agent" && DebugScene.defaults.integer(forKey: "CuePadHistory") > 0 && DebugScene.searchText.isEmpty ? .bottom : nil)
        #endif
        .safeAreaBar(edge: .top) {
            SearchRow(search: search) { if project == nil { actions } }
        }
        .modifier(Header(pushed: project != nil, count: list.map { $0.now.count + $0.total }, filter: filter))
        // 标签页的根：系统导航栏收起，只留这一排（iPad 分栏里导航栏放着分栏自己的按钮，留着）
        .toolbarVisibility(project == nil && navigation.layout == .tabs ? .hidden : .automatic, for: .navigationBar)
        .refreshable { await services.syncNow() }
        .onChange(of: query) { limit = PiSessionList.pageSize }
        .onChange(of: filter) { limit = PiSessionList.pageSize }
        #if DEBUG
        .onAppear { if DebugScene.scene == "agent" { query = DebugScene.searchText } }
        #endif
        .observing(services.store, [.piSessionStates, .deliveryRequests, .projects, .directoryBindings],
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
    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        let filtered = list.filter.project != nil
        if list.isEmpty {
            empty.listRowBackground(Color.clear)
        } else {
            Group {
                if !list.now.isEmpty {
                    Section {
                        ForEach(list.now) { row($0, filtered: filtered) }
                    } header: { SectionTitle(text: "现在").listRowInsets(Self.headerInsets) }
                }
                let runs = PiHistorySection.split(list.ended, date: \.state.stateSince, now: .now)
                ForEach(Array(runs.enumerated()), id: \.element.section) { index, run in
                    Section {
                        ForEach(run.items) { row($0, filtered: filtered) }
                    } header: {
                        VStack(alignment: .leading, spacing: 10) {
                            if index == 0 { SectionTitle(text: "历史") }
                            Text(run.section.title).font(.footnote.weight(.medium)).foregroundStyle(palette.ink3).padding(.horizontal, 4)
                        }
                        .listRowInsets(Self.headerInsets)
                    }
                }
                if list.loaded < list.total {
                    // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                        .task(id: list.loaded) { limit = list.loaded + PiSessionList.pageSize }
                }
            }
            .transaction(value: list.filter) { $0.animation = nil }
            .animation(Motion.quick, value: list.now.map(\.id))
            .animation(Motion.quick, value: list.now.map(\.state.state))
            .animation(Motion.quick, value: (list.now + list.ended).map(\.delivery?.status))
            .animation(Motion.quick, value: ending)
        }
    }

    /// 分组标题与纸面左缘对齐（列表默认再缩进一截）。
    private static let headerInsets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    /// 一行：纸底，分隔线从名字起；在线的会话长按与左滑都有"结束会话"。
    private func row(_ item: PiSessionListItem, filtered: Bool) -> some View {
        let live = item.state.state != .known(.ended)
        return SessionRow(item: item, filtered: filtered, ending: ending[item.id])
            .listRowInsets(.init())
            .listRowBackground(palette.paper)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 44 }
            .swipeActions(edge: .trailing) {
                if live, ending[item.id] != .running {
                    Button("结束会话", systemImage: "stop.circle") { confirmingEnd = item.state }.tint(palette.failure)
                }
            }
            .contextMenu {
                if live, ending[item.id] != .running {
                    Button("结束会话", systemImage: "stop.circle", role: .destructive) { confirmingEnd = item.state }
                }
            }
    }

    /// 请会话所在的 Mac 结束它，等到结果：成功后它进"历史"（不留提示），没能结束就在那一行写原因。
    private func end(_ session: PiSessionState) {
        ending[session.id] = .running
        Task {
            do {
                let request = try await services.end(session)
                let outcome = try await services.outcome(of: request.id)
                if outcome.status == .known(.failed) {
                    ending[session.id] = .failed(outcome.resultDetail ?? "没能结束")
                } else {
                    ending[session.id] = nil
                }
            } catch {
                ending[session.id] = .failed(error.localizedDescription)
            }
        }
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

    private var search: SearchCapsule {
        SearchCapsule(prompt: "搜会话、目录、说过的话", query: $query, focus: $searchFocused)
    }

    @ViewBuilder private var actions: some View {
        if !services.syncStatus.reachesMac { SyncBadge(status: services.syncStatus) }
        NewSessionButton(project: filter)
    }
}

/// 标签根页（灵感、Agent）与 iPad 右侧面板的顶上一排：搜索框占满左边，右边圆钮。浮在内容上（滚动到它下面的内容渐隐），
/// 不放进导航栏：导航栏中间那一格按内容宽度居中，占不满。
/// 没有可搜的东西时 `search` 为 nil，圆钮仍靠右。
struct SearchRow<Trailing: View>: View {
    let search: SearchCapsule?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let search { search } else { Spacer() }
            trailing
        }
        .buttonStyle(CircleGlass()).menuStyle(.button).labelStyle(.iconOnly)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
    }
}

/// 顶上一排的圆钮：与搜索框同高的一颗玻璃圆（菜单的"⋯"同一种）。
private struct CircleGlass: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium)).foregroundStyle(palette.ink)
            .frame(width: SearchCapsule.height, height: SearchCapsule.height)
            .contentShape(.circle)
            .glass(in: .circle, interactive: true)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 顶上一排的搜索框：玻璃胶囊。在输入或有字时右端一个叉：清空并收起键盘。
struct SearchCapsule: View {
    static let height: CGFloat = 44
    let prompt: String
    @Binding var query: String
    let focus: FocusState<Bool>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $query).submitLabel(.search).focused(focus).accessibilityLabel("搜索")
            if !query.isEmpty || focus.wrappedValue {
                Button("清除", systemImage: "xmark.circle.fill") {
                    query = ""
                    focus.wrappedValue = false
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette.ink3)
            }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: Self.height)
        .glass(in: .capsule)
    }
}

/// 从项目页推入的那一页：悬浮顶栏写此刻筛的项目名（换成"全部"时写"全部会话"）与会话数，右边新会话。标签根页与 iPad 面板不挂顶栏，
/// 标题"Agent"只作读屏、切换器与返回菜单里的名字。
private struct Header: ViewModifier {
    let pushed: Bool
    let count: Int?
    let filter: UUID?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        if pushed {
            content.floatingHeader(workspace.catalog?.project(filter)?.name ?? "全部会话", detail: count.map { "\($0) 个会话" }) {
                NewSessionButton(project: filter)
            }
        } else {
            content.navigationTitle("Agent").navigationBarTitleDisplayMode(.inline)
        }
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
        Button { open = true } label: {
            Label(summary.title, systemImage: summary.symbol).foregroundStyle(summary.color(palette))
        }
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

/// 结束会话的进行中与失败（成功后会话进"历史"，不留状态）。
private enum Ending: Equatable {
    case running
    case failed(String)
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
        let deliveries = Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
        let order = Dictionary(uniqueKeysWithValues: PiSessionState.inListOrder(live.map(\.state), deliveries: deliveries).enumerated().map { ($1.id, $0) })
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
    var ending: Ending?
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let session = item.state
        let shown = services.settings.shown(item)
        let place = filtered ? nil : PiPlace.name(of: session, project: item.project)
        Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
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
                    switch ending {
                    case .running:
                        Text("正在结束…").font(.subheadline).foregroundStyle(palette.ink3)
                    case .failed(let reason):
                        Text(reason).font(.subheadline).foregroundStyle(palette.failure).lineLimit(2)
                    case nil:
                        if let progress = PiProgress.line(of: session) {
                            Text(progress).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
                        }
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

