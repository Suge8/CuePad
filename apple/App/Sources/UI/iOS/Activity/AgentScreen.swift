#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// Agent 页：只回答"每个会话在做什么、现在到哪了、结果或卡点是什么"。"现在"是没结束的会话，按要你注意的先后排
/// （等你确认 → 出错 → 工作中 → 空闲）；"历史"是所有已结束的，按结束时间分段（今天、昨天……）、可搜，滑到底才读下一页。
/// 点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。顶上一排（`SearchRow`）：左边按项目筛，中间搜索，
/// 右边新会话（同步到不了 Mac 时多一颗同步图标）；从项目页"全部 N 个会话"推入的那一页用推入页的悬浮顶栏（项目名、会话数、新会话），
/// 筛选与搜索在它下面一排。在线会话长按或左滑可结束（确认后发给它所在的 Mac，对话留着）。
struct AgentScreen: View {
    var inPanel = false
    /// 从项目页进来：先筛这个项目，在这里换的筛选不记下。
    var project: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var model = AgentListModel()
    /// 推入页自己的筛选（进来时是那个项目，在这里换的不记）；标签根页的筛选记在偏好里。
    @State private var pushedFilter: UUID?
    @FocusState private var searchFocused: Bool
    @State private var searchHidden = false
    /// 还没有文件夹的项目的同名建议（顶上筛选钮的菜单里一键绑）。
    @State private var folderGuide: FolderGuide?
    @Environment(\.tabPageReady) private var tabPageReady

    init(inPanel: Bool = false, project: UUID? = nil) {
        self.inPanel = inPanel
        self.project = project
        _pushedFilter = State(initialValue: project)
    }

    /// 此刻的项目筛选；项目进了回收站时是全部。
    private var filter: UUID? {
        if project == nil { return navigation.agentFilter(catalog: workspace.catalog) }
        return pushedFilter.flatMap { workspace.catalog?.project($0)?.id }
    }

    private func pick(_ id: UUID?) {
        if project == nil { navigation.chooseAgentFilter(id) } else { pushedFilter = id }
    }

    var body: some View {
        List {
            if let list = model.list { sessions(list) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(16)
        // 与书架同一页边距与顶距：顶上不留分组列表默认的空白，只让出搜索那一排下面统一的一小段
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.top, Bars.contentGap, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        #if DEBUG
        .defaultScrollAnchor(DebugScene.scene == "agent" && DebugScene.defaults.integer(forKey: "CuePadHistory") > 0 && DebugScene.searchText.isEmpty ? .bottom : nil)
        #endif
        .hidingSearch($searchHidden, searching: searchFocused || !model.query.isEmpty)
        .fadesUnderBars(below: Bars.contentGap)
        .safeAreaBar(edge: .top) {
            SearchRow(search: search, searchHidden: searchHidden) { filterMenu } trailing: { if project == nil { actions } }
        }
        .modifier(Header(pushed: project != nil, count: model.list.map { $0.now.count + $0.total }, filter: filter))
        // 标签页的根：系统导航栏收起，只留这一排（iPad 分栏里导航栏放着分栏自己的按钮，留着）
        .toolbarVisibility(project == nil && navigation.layout == .tabs ? .hidden : .automatic, for: .navigationBar)
        .observingFolderGuide(into: $folderGuide)
        .refreshable { await services.syncNow() }
        .onChange(of: model.list != nil, initial: true) { _, loaded in if loaded { tabPageReady() } }
        .agentList(model, filter: filter)
        #if DEBUG
        .onAppear { if DebugScene.scene == "agent" { model.query = DebugScene.searchText } }
        #endif
    }

    /// 左边的圆钮：按项目筛"现在"与"历史"（全部 + 在 Mac 上绑了文件夹的项目，项目目录的顺序）；筛着项目时圆钮里是那个项目的图标。
    /// 钮始终在（两个标签根页的顶上一排结构一致）；一个能筛的项目都没有时点开写明原因，并给还没绑文件夹的项目各一项去绑。
    @ViewBuilder private var filterMenu: some View {
        let projects = model.filterable(in: workspace.catalog, current: filter)
        let current = workspace.catalog?.project(filter)
        Menu {
            if projects.isEmpty {
                Section("绑定文件夹后，那里的 Agent 会话才能按项目看") {
                    ForEach((workspace.catalog?.projects ?? []).filter { !workspace.hasFolder($0.id) }) { project in
                        // 有同名文件夹的一键绑（会话数写在上面），其余自己选
                        if let named = folderGuide?.suggestions[project.id]?.first {
                            Button { bind(named, to: project) } label: {
                                Label { Text(ProjectFolders.suggestionTitle(named, showsMac: false)) } icon: { Image(systemName: "folder.badge.plus") }
                            }
                        } else {
                            Button { workspace.chooseFolder(for: project) } label: {
                                Label("为「\(project.name)」绑定文件夹…", systemImage: "folder.badge.plus")
                            }
                        }
                    }
                }
            } else {
                Picker("按项目看", selection: Binding { filter } set: { pick($0) }) {
                    Label("全部", systemImage: "square.stack").tag(UUID?.none)
                    ForEach(projects) { project in
                        Label { Text(project.name) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                    }
                }
            }
        } label: {
            Label {
                Text(current.map { "按项目看：\($0.name)" } ?? "按项目看")
            } icon: {
                if let current { ProjectGlyph(project: current, size: 15) } else { Image(systemName: "line.3.horizontal.decrease") }
            }
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func bind(_ candidate: ProjectFolders.Candidate, to project: Project) {
        let id = project.id, name = project.name
        workspace.attempt { try await workspace.requestFolder(PiBind(project: id, folder: candidate.target), title: name, on: candidate.hostID) }
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
                        ForEach(list.nowRows) { nowRow in
                            switch nowRow {
                            case .session(let item): row(item, filtered: filtered, end: list.ends[item.id])
                            case .reload(let items):
                                PiReloadFold(count: items.count, expanded: $model.reloadOpen, style: .page)
                                    .padding(.horizontal, 16).padding(.vertical, Self.rowPadding)
                                    .listRowInsets(.init()).listRowBackground(palette.paper).listRowSeparator(.hidden)
                                if model.reloadOpen { ForEach(items) { row($0, filtered: filtered, end: list.ends[$0.id]) } }
                            }
                        }
                    } header: { SectionTitle(text: "现在").listRowInsets(Self.headerInsets) }
                }
                ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                    Section {
                        ForEach(run.items) { row($0, filtered: filtered, end: list.ends[$0.id]) }
                    } header: {
                        VStack(alignment: .leading, spacing: 10) {
                            if index == 0 { SectionTitle(text: "历史") }
                            Text(run.section.title).font(.footnote.weight(.medium)).foregroundStyle(palette.ink3).padding(.horizontal, 4)
                        }
                        .listRowInsets(Self.headerInsets)
                    }
                }
                if model.hasMore {
                    // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                    Spinner(.regular).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                        .task(id: list.loaded) { model.loadMore() }
                }
            }
            .transaction(value: list.filter) { $0.animation = nil }
            .animation(Motion.snappy, value: list.now.map(\.id))
            .animation(Motion.quick, value: list.now.map(\.state.state))
            .animation(Motion.quick, value: (list.now + list.ended).map(\.delivery?.status))
            .animation(Motion.quick, value: list.ends.mapValues(\.status))
        }
    }

    /// 分组标题与纸面左缘对齐（列表默认再缩进一截）。
    private static let headerInsets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    /// 行的上下留白：行之间不画分隔线，三行字靠留白分开（与 Mac 的 Agent 整页一样）。
    static let rowPadding: CGFloat = 11

    /// 一行：纸底；长按与左滑都有"结束会话"（在线的）与"重命名"（读得到的会话；Mac 够不着时置灰，会话页"⋯"里同一个说法）。
    private func row(_ item: PiSessionListItem, filtered: Bool, end: DeliveryRequest?) -> some View {
        let endable = MacDelivery.canEnd(item.state) && end?.isOpen != true
        let renamable = MacDelivery.canRename(item.state)
        // 结束不是删除：墨色，确认框里再说清后果；会话记录没有删除（会话文件在 Mac 上，归 Pi 管）
        let trailing = (endable ? [RowAction("结束会话", symbol: "stop.circle") { model.confirmingEnd = item.state }] : [])
            + (renamable ? [RowAction("重命名", symbol: "pencil", tone: .quiet, enabled: services.reachesPiHost) { model.renaming = item.state }] : [])
        return SessionRow(item: item, filtered: filtered, end: end)
            .listRowInsets(.init())
            .listRowBackground(palette.paper)
            .listRowSeparator(.hidden)
            .listSwipes(RowSwipes(trailing: trailing))
            .contextMenu {
                MarkUnreadButton(session: item.state)
                RowActionButtons(actions: trailing.reversed())
            }
    }


    @ViewBuilder private var empty: some View {
        let project = filter.flatMap { workspace.catalog?.project($0) }
        switch model.empty(filtering: project, hasFolder: filter.map(workspace.hasFolder) ?? true) {
        case .noMatch(let query):
            EmptyState.noMatch(query).padding(.top, 40)
        case .needsFolder(let project):
            EmptyState(mascot: .empty, title: "还没绑定文件夹", message: "绑定后，在那个文件夹里跑的 Agent 会话会出现在这里") {
                ProjectFolderGuide(project: project, guide: folderGuide)
            }
            .padding(.top, 40)
        case .none(inProject: true):
            EmptyState(mascot: .empty, title: "这个项目还没有 Agent 会话") {
                EmptyStateButton(title: "新会话", systemImage: "plus", action: { navigation.newSession = .init(project: filter) })
            }
            .padding(.top, 40)
        case .none(inProject: false):
            EmptyState(mascot: .empty, title: "还没有 Agent 会话", message: "在 Mac 上运行 pi，或在这里开一个新会话") {
                EmptyStateButton(title: "新会话", systemImage: "plus", action: { navigation.newSession = .init() })
            }
            .padding(.top, 40)
        }
    }

    private var search: SearchCapsule {
        SearchCapsule(prompt: workspace.catalog?.project(filter).map { "搜 \($0.name) 的会话" } ?? "搜索会话", query: $model.query, focus: $searchFocused)
    }

    @ViewBuilder private var actions: some View {
        if !services.syncStatus.reachesMac { SyncBadge(status: services.syncStatus) }
        NewSessionButton(project: filter)
    }
}

/// 标签根页（灵感、Agent）与 iPad 右侧面板的顶上一排：左右各一颗圆钮，中间搜索框占满。浮在内容上（滚动到它下面的内容渐隐），
/// 不放进导航栏：导航栏中间那一格按内容宽度居中，占不满。往下滑时搜索框藏起、两颗圆钮留着（主控件不跟着滚动来回跳），
/// 往上滑或回到顶上再出现（`hidesSearch`）；只淡出、不改这一排的高度，免得内容跟着挪、滚动位置反过来又改它。
/// 没有可搜的东西时 `search` 为 nil，两颗圆钮仍各在两端。
struct SearchRow<Leading: View, Trailing: View>: View {
    let search: SearchCapsule?
    var searchHidden = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            // 藏起时整个移走：只把透明度调到 0 时玻璃的边与投影还留着，两颗圆钮之间像一条空搜索框
            ZStack {
                if let search, !searchHidden {
                    search.transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .frame(maxWidth: .infinity)
            trailing
        }
        .buttonStyle(ControlButtonStyle(kind: .circular)).menuStyle(.button).labelStyle(.iconOnly)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
        .animation(Motion.quick, value: searchHidden)
    }
}

extension SearchRow where Leading == EmptyView, Trailing == EmptyView {
    /// 离顶这么近时总是露出搜索框：刚开始滑、下拉回弹时不闪。
    static var revealZone: CGFloat { 24 }

    /// 滚动从 `old` 到 `new`（内容偏移，0 是顶）之后搜索框藏不藏。
    static func hidesSearch(_ hidden: Bool, from old: CGFloat, to new: CGFloat, searching: Bool) -> Bool {
        if searching || new <= revealZone { return false }
        return new == old ? hidden : new > old
    }
}

extension View {
    /// 跟着滚动藏起、露出顶上那一排的搜索框（`SearchRow.hidesSearch`）。
    func hidingSearch(_ hidden: Binding<Bool>, searching: Bool) -> some View {
        // 偏移夹在能滚到的范围里：滚到底回弹的那一下不算往上滑
        onScrollGeometryChange(for: CGFloat.self, of: { geometry in
            let top = geometry.contentInsets.top
            let end = geometry.contentSize.height - geometry.containerSize.height
            return min(max(geometry.contentOffset.y + top, 0), max(end, 0))
        }) { old, new in
            let next = SearchRow.hidesSearch(hidden.wrappedValue, from: old, to: new, searching: searching)
            if next != hidden.wrappedValue { hidden.wrappedValue = next }
        }
    }
}

/// 顶上一排的搜索框：玻璃胶囊。在输入或有字时右端一个叉：清空并收起键盘。
struct SearchCapsule: View {
    static let height: CGFloat = ControlMetrics.height
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
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .quiet, compact: true))
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
            .accessibilityHint("让 Mac 开一个 Agent 会话")
    }
}

/// 同步到不了 Mac 时的同步图标（平时不出现）：点开看哪里不通。图标是次要墨色，右上一个小点带状态色（提示赭黄，真出错才胭脂），
/// 不让整颗圆钮变成警报。
private struct SyncBadge: View {
    let status: SyncStatus
    @Environment(\.palette) private var palette
    @State private var open = false

    var body: some View {
        let summary = SyncSummary(status)
        Button { open = true } label: {
            Label(summary.title, systemImage: summary.symbol).foregroundStyle(palette.ink2)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(summary.color(palette)).frame(width: 6, height: 6).offset(x: 3, y: -1).accessibilityHidden(true)
                }
        }
            .popover(isPresented: $open) {
                SyncHint(status: status).padding(16).frame(idealWidth: 280).fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
    }
}


private struct SectionTitle: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        // 分组标题是页面的骨架：不比行里的字弱
        Text(text).font(.headline).foregroundStyle(palette.ink)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 一个会话（`PiSessionRow`）点开它的会话页；已结束的整行更淡。
private struct SessionRow: View {
    let item: PiSessionListItem
    let filtered: Bool
    /// 此刻要显示的结束请求（`DeliveryRequest.shownEnd`）。
    var end: DeliveryRequest?
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services

    var body: some View {
        let session = item.state
        Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
            PiSessionRow(session: session, project: filtered ? nil : item.project, delivery: item.delivery, end: end, rename: item.rename, undelivered: item.undelivered, style: .page).equatable()
                .padding(.horizontal, 16).padding(.vertical, AgentScreen.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、回复" : "看近况、回复")
    }
}
#endif

