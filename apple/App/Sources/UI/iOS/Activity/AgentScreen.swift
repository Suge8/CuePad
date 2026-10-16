#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// Agent 整页（iPhone 从 Cue 页头面板的"全部会话"、项目页的"全部 N 个会话"推入；iPad 侧栏的"会话"）：只回答"每个会话在做什么、
/// 现在到哪了、结果或卡点是什么"。会话列表是 `SessionList`；顶栏是推入页的悬浮顶栏（筛着的项目名或"全部会话"、会话数、新会话），
/// 列表最上面一排项目胶囊按项目筛（只有在 Mac 上绑了文件夹的项目能筛：会话按工作目录归入项目），筛选只留在这一页上、不记。
/// 搜会话在搜索页（右下的搜索圆钮），这里不另放搜索框；订阅额度在 Cue 页头的面板里。
struct AgentScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var model = AgentListModel()
    /// 此刻筛的项目；从项目页进来先筛它。选中的项目进了回收站时是全部。
    @State private var chosen: UUID?

    init(project: UUID? = nil) {
        _chosen = State(initialValue: project)
    }

    private var filter: UUID? { chosen.flatMap { workspace.catalog?.project($0)?.id } }

    var body: some View {
        SessionList(model: model, filter: filter) { chips }
            .floatingHeader(workspace.catalog?.project(filter)?.name ?? "全部会话", detail: model.list.map { "\($0.now.count + $0.total) 个会话" }) {
                NewSessionButton(project: filter)
            }
    }

    /// 项目胶囊：全部 + 在 Mac 上绑了文件夹的项目（项目目录的顺序）；一个能筛的项目都没有时不占这一行。
    @ViewBuilder private var chips: some View {
        let projects = model.filterable(in: workspace.catalog, current: filter)
        if !projects.isEmpty {
            ChipRow {
                chip(nil) { Text("全部") }
                ForEach(projects) { project in
                    chip(project.id) {
                        Label { Text(project.name) } icon: { ProjectGlyph(project: project, size: 14) }
                    }
                }
            }
            .padding(.horizontal, -16)
            .sensoryFeedback(.selection, trigger: filter)
        }
    }

    private func chip(_ project: UUID?, @ViewBuilder label: () -> some View) -> some View {
        let on = filter == project
        return Button { chosen = project } label: { FilterChip(on: on, label: label) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 会话列表（Agent 整页、搜索页的会话一栏同一个）："现在"是没结束的会话，按要你注意的先后排（等你确认 → 出错 → 工作中 → 空闲）；
/// "历史"是所有已结束的，按结束时间分段（今天、昨天……），滑到底才读下一页。搜索词在 `model.query` 里（搜索页给），命中的字高亮。
/// 点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。在线会话长按或左滑可结束（确认后发给它所在的 Mac，对话留着）。
/// `top` 是列表最上面一行（Agent 页的项目胶囊），跟着列表一起滚走。
struct SessionList<Top: View>: View {
    @Bindable var model: AgentListModel
    let filter: UUID?
    @ViewBuilder var top: Top
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            top.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let list = model.list { sessions(list) }
        }
        // 每个会话一张卡片（`sessionCard`）：平铺列表、行不画底，分组标题是普通的行（平铺列表的分组标题会吸顶）
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.top, Bars.contentGap, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .loading(model.list == nil)
        .refreshable { await services.syncNow() }
        .agentList(model, filter: filter)
    }

    /// 会话列表。换搜索词或项目时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）；同一筛选下会话进出、换状态才有动画。
    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        let filtered = list.filter.project != nil
        if list.isEmpty {
            empty.listRowBackground(Color.clear)
        } else {
            Group {
                if !list.now.isEmpty {
                    header { SectionTitle(text: "现在") }
                    ForEach(list.nowRows) { nowRow in
                        switch nowRow {
                        case .session(let item): row(item, filtered: filtered, end: list.ends[item.id])
                        case .reload(let items):
                            PiReloadFold(count: items.count, expanded: $model.reloadOpen, style: .page)
                                .sessionCard()
                                .cardRow()
                            if model.reloadOpen { ForEach(items) { row($0, filtered: filtered, end: list.ends[$0.id]) } }
                        }
                    }
                }
                ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                    header {
                        VStack(alignment: .leading, spacing: 10) {
                            if index == 0 { SectionTitle(text: "历史") }
                            Text(run.section.title).font(.footnote.weight(.medium)).foregroundStyle(palette.ink3).padding(.horizontal, 4)
                        }
                    }
                    ForEach(run.items) { row($0, filtered: filtered, end: list.ends[$0.id]) }
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
            .animation(Motion.quick, value: list.ends)
        }
    }

    /// 分组标题：与卡片左缘对齐，上面多留一段把分组分开。
    private func header(@ViewBuilder _ title: () -> some View) -> some View {
        title()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    /// 一张卡片：长按与左滑都有"结束会话"（在线的）与"重命名"（读得到的会话；Mac 够不着时置灰，会话页"⋯"里同一个说法）。
    private func row(_ item: PiSessionListItem, filtered: Bool, end: Speech.Trip?) -> some View {
        let endable = item.state.canEnd && end != .sending
        let renamable = MacDelivery.canRename(item.state)
        // 结束不是删除：墨色，确认框里再说清后果；会话记录没有删除（会话文件在 Mac 上，归 Pi 管）
        let trailing = (endable ? [RowAction("结束会话", symbol: "stop.circle") { model.confirmingEnd = item.state }] : [])
            + (renamable ? [RowAction("重命名", symbol: "pencil", tone: .quiet, enabled: services.reachesPiHost) { model.renaming = item.state }] : [])
        return SessionRow(item: item, filtered: filtered, end: end)
            .cardRow()
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
                ProjectFolderGuide(project: project, guide: workspace.folderGuide)
            }
            .padding(.top, 40)
        case .none(inProject: true):
            EmptyState(mascot: .empty, title: "这个项目还没有 Agent 会话", waitsForSync: true) {
                EmptyStateButton(title: "新会话", systemImage: "plus", action: { navigation.newSession = .init(project: filter) })
            }
            .padding(.top, 40)
        case .none(inProject: false):
            let hasProjects = workspace.catalog?.projects.isEmpty == false
            EmptyState(
                mascot: .empty, title: "还没有 Agent 会话",
                message: hasProjects ? "在 Mac 的终端里开一个 Agent，或在这里开新会话" : "在 Mac 的终端里开一个 Agent，或新建项目后在这里开会话",
                waitsForSync: true
            ) {
                EmptyStateButton(
                    title: hasProjects ? "新会话" : "新建项目", systemImage: hasProjects ? "plus" : "folder.badge.plus",
                    action: { navigation.startNewSession(hasProjects: hasProjects) })
            }
            .padding(.top, 40)
        }
    }
}

extension SessionList where Top == EmptyView {
    init(model: AgentListModel, filter: UUID?) { self.init(model: model, filter: filter) { EmptyView() } }
}

/// 新会话；筛着某个项目时新会话先选它。
private struct NewSessionButton: View {
    let project: UUID?
    @Environment(Navigation.self) private var navigation
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新会话", systemImage: "plus") {
            navigation.startNewSession(.init(project: project), hasProjects: workspace.catalog?.projects.isEmpty == false)
        }
            .accessibilityHint("让 Mac 开一个 Agent 会话")
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
    var end: Speech.Trip?
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services

    var body: some View {
        let session = item.state
        Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
            PiSessionRow(session: session, project: filtered ? nil : item.project, delivery: item.delivery, end: end, rename: item.rename, undelivered: item.undelivered(at: services.speech), style: .page).equatable()
                .contentShape(.rect(cornerRadius: SessionCard.radius))
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、回复" : "看近况、回复")
    }
}

private extension View {
    /// 会话卡片在列表里的一行：行不画底、不画分隔线，卡片之间留 8 点。
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
#endif
