#if os(iOS)
import CueStore
import SwiftUI

/// 会话页（iPhone 底部一排与宽屏侧栏的"会话"；也从 Cue 页头面板的"全部会话"、项目页的"全部 N 个会话"推入）：只回答"每个会话在做什么、
/// 现在到哪了、结果或卡点是什么"。会话列表是 `SessionList`；标题是"会话"（下面一行会话数；窄屏的根不写标题与那一行，`homePage`），右边新会话，
/// 列表最上面一排项目胶囊按项目筛（选中的那颗是选中底与靛青字，`FilterChip`）（只有在 Mac 上绑了文件夹的项目与未分类能筛：会话按工作目录归入项目），
/// 筛选只留在这一页上、不记；不筛时列表按项目分组，组头的"全部 N 个"就是筛这个项目。
/// 搜会话在搜索页（iPhone 顶栏左边的搜索钮、iPad 侧栏顶上的搜索框），这里不另放搜索框；订阅额度在 Cue 页头的面板里。
struct AgentScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var model = AgentListModel()
    /// 此刻筛的项目或未分类；从项目页进来先筛它。选中的项目进了回收站时是全部。
    @State private var chosen: PiSessionProject?

    init(project: UUID? = nil) {
        _chosen = State(initialValue: project.map(PiSessionProject.project))
    }

    private var filter: PiSessionProject? {
        guard case .project(let id) = chosen else { return chosen }
        return workspace.catalog?.project(id) == nil ? nil : chosen
    }

    var body: some View {
        SessionList(model: model, filter: filter, choose: { chosen = $0 }) { chips }
            .floatingHeader(SidebarOutline.Entry.sessions.title, detail: model.list.map { "\($0.count) 个会话" }) {
                NewSessionButton(project: filter?.id)
            }
    }

    /// 项目胶囊：全部、在 Mac 上绑了文件夹的项目（项目目录的顺序）、未分类；一个能筛的项目都没有时不占这一行。
    @ViewBuilder private var chips: some View {
        let projects = model.filterable(in: workspace.catalog, current: filter?.id)
        if !projects.isEmpty {
            ChipRow {
                chip(nil) { Text("全部") }
                ForEach(projects) { project in
                    chip(.project(project.id)) {
                        // 不用 Label：iOS 的 Label 给图标留一格固定宽，小图标与字之间空出二十多点。项目图标两边各自带 3 点的格（`ProjectGlyph`），
                        // 这里再隔 3 点，看上去图标与字隔 6 点
                        HStack(spacing: 3) {
                            ProjectGlyph(project: project, size: 14)
                            Text(project.name)
                        }
                    }
                }
                chip(.unfiled) {
                    HStack(spacing: 3) {
                        ProjectGlyph(project: nil, size: 14)
                        Text(CaptureCopy.unfiled)
                    }
                }
            }
            .padding(.horizontal, -16)
            .sensoryFeedback(.selection, trigger: filter)
        }
    }

    private func chip(_ place: PiSessionProject?, @ViewBuilder label: () -> some View) -> some View {
        let on = filter == place
        return Button { chosen = place } label: { FilterChip(on: on, label: label) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 会话列表（会话页、搜索页的会话一栏同一个，数据是两端共用的 `PiSessionList`）：不筛也不搜时按项目分组——组头是项目与几个在线，
/// 先列它在线的（按要你注意的先后：等你确认 → 出错 → 工作中 → 空闲）、再列最近结束的几条，结束的更多时组头右边"全部 N 个"按这个项目筛（`choose`；搜索页不给，不显示），
/// 没有项目的归"未分类"一组。筛着或在搜时"现在"是没结束的，"历史"是已结束的、按结束时间分段（今天、昨天……），滑到底才读下一页；只有搜索的平铺结果在卡上写所在。
/// 搜索词在 `model.query` 里（搜索页给），命中的字高亮。点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。
/// 在线会话长按或左滑可结束（确认后发给它所在的 Mac，对话留着）。`top` 是列表最上面一行（会话页的项目胶囊），跟着列表一起滚走；换筛选时回到它。
struct SessionList<Top: View>: View {
    @Bindable var model: AgentListModel
    let filter: PiSessionProject?
    var choose: ((PiSessionProject) -> Void)?
    @ViewBuilder var top: Top
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    /// 最上面那一行的 id：换筛选时滚回它（泛型类型里不能有静态存储属性）。
    private var topID: String { "top" }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                top.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).id(topID)
                if let list = model.list { sessions(list) }
            }
            // 每个会话一张卡片（`sessionCard`）：平铺列表、行不画底，分组标题是普通的行（平铺列表的分组标题会吸顶）
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .contentMargins(.top, Bars.contentGap, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await services.syncNow() }
            // 组头的"全部"在页中间换筛选：换完回到顶上，从这个项目的第一条看起
            .onChange(of: filter) { proxy.scrollTo(topID, anchor: .top) }
        }
        .agentList(model, filter: filter)
    }

    /// 会话列表。换搜索词或项目时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）；同一筛选下会话进出、换状态才有动画。
    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        if list.isEmpty {
            empty.listRowBackground(Color.clear)
        } else {
            Group {
                if case .grouped(let groups) = list.history {
                    ForEach(groups) { group in
                        header { GroupTitle(group: group, choose: choose) }
                        nowRows(group.now, in: list)
                        ForEach(group.ended) { row($0, in: list, end: nil) }
                    }
                } else {
                    if !list.now.isEmpty {
                        header { SectionTitle(text: "现在") }
                        nowRows(list.now, in: list)
                    }
                    ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                        header {
                            VStack(alignment: .leading, spacing: 10) {
                                if index == 0 { SectionTitle(text: "历史") }
                                Text(run.section.title).font(.footnote.weight(.medium)).foregroundStyle(palette.ink3).padding(.horizontal, 4)
                            }
                        }
                        ForEach(run.items) { row($0, in: list, end: list.ends[$0.id]) }
                    }
                    if model.hasMore {
                        // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                        Spinner(.regular).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                            .task(id: list.loaded) { model.loadMore() }
                    }
                }
            }
            .transaction(value: list.filter) { $0.animation = nil }
            .animation(Motion.snappy, value: list.now.map(\.id))
            .animation(Motion.quick, value: list.now.map(\.state.state))
            .animation(Motion.quick, value: (list.now + list.ended).map(\.delivery?.status))
            .animation(Motion.quick, value: list.ends)
        }
    }

    /// 在线的会话，两个以上需要 /reload 的合成一行（`PiNowRow`）。
    @ViewBuilder private func nowRows(_ items: [PiSessionListItem], in list: PiSessionList) -> some View {
        ForEach(PiNowRow.rows(items, state: \.state)) { nowRow in
            switch nowRow {
            case .session(let item): row(item, in: list, end: list.ends[item.id])
            case .reload(let items):
                PiReloadFold(count: items.count, expanded: $model.reloadOpen, style: .page)
                    .sessionCard()
                    .cardRow()
                if model.reloadOpen { ForEach(items) { row($0, in: list, end: list.ends[$0.id]) } }
            }
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
    private func row(_ item: PiSessionListItem, in list: PiSessionList, end: Speech.Trip?) -> some View {
        let endable = item.state.canEnd && end != .sending
        let renamable = MacDelivery.canRename(item.state)
        // 结束不是删除：墨色，确认框里再说清后果；会话记录没有删除（会话文件在 Mac 上，归 Pi 管）
        let trailing = (endable ? [RowAction("结束会话", icon: .endSession) { model.confirmingEnd = item.state }] : [])
            + (renamable ? [RowAction("重命名", icon: .rename, tone: .quiet, enabled: services.reachesPiHost) { model.renaming = item.state }] : [])
        return SessionRow(item: item, showsPlace: list.showsPlace, end: end)
            .cardRow()
            .listSwipes(RowSwipes(trailing: trailing))
            .contextMenu {
                MarkUnreadButton(session: item.state)
                RowActionButtons(actions: trailing.reversed())
            }
    }

    @ViewBuilder private var empty: some View {
        let empty = model.empty(filter: filter, in: workspace)
        switch empty {
        case .noMatch(let query):
            EmptyState.noMatch(query).padding(.top, 40)
        case .needsFolder(let project):
            EmptyState(mascot: .empty, title: "还没绑定文件夹", message: "绑定后，在那个文件夹里跑的 Agent 会话会出现在这里") {
                ProjectFolderGuide(project: project, guide: workspace.folderGuide)
            }
            .padding(.top, 40)
        case .none(.some):
            EmptyState(mascot: .empty, title: empty.noneTitle, waitsForSync: true) {
                EmptyStateButton(title: "新会话", icon: .add, action: { navigation.newSession = .init(project: filter?.id) })
            }
            .padding(.top, 40)
        case .none(nil):
            let hasProjects = workspace.catalog?.projects.isEmpty == false
            EmptyState(
                mascot: .empty, title: empty.noneTitle,
                message: hasProjects ? "在 Mac 的终端里开一个 Agent，或在这里开新会话" : "在 Mac 的终端里开一个 Agent，或新建项目后在这里开会话",
                waitsForSync: true
            ) {
                EmptyStateButton(
                    title: hasProjects ? "新会话" : "新建项目", icon: hasProjects ? .add : .newProject,
                    action: { navigation.startNewSession(hasProjects: hasProjects) })
            }
            .padding(.top, 40)
        }
    }
}

extension SessionList where Top == EmptyView {
    init(model: AgentListModel, filter: PiSessionProject?) { self.init(model: model, filter: filter) { EmptyView() } }
}

/// 新会话；筛着某个项目时新会话先选它。
private struct NewSessionButton: View {
    let project: UUID?
    @Environment(Navigation.self) private var navigation
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新会话", icon: .add) {
            navigation.startNewSession(.init(project: project), hasProjects: workspace.catalog?.projects.isEmpty == false)
        }
            .accessibilityHint("让 Mac 开一个 Agent 会话")
    }
}

/// 分组时一组的组头：项目图标与名字、几个在线；结束的还有没列出来的、又给了 `choose` 时右边"全部 N 个"按这个项目筛。
private struct GroupTitle: View {
    let group: PiSessionList.Group
    let choose: ((PiSessionProject) -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        let name = group.project?.name ?? CaptureCopy.unfiled
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProjectGlyph(project: group.project, size: 15)
            Text(name).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if !group.now.isEmpty {
                Text("\(group.now.count) 个在线").font(.subheadline).monospacedDigit().foregroundStyle(palette.ink3)
            }
            Spacer(minLength: 8)
            if group.hasMore, let choose {
                Button { choose(group.place) } label: {
                    HStack(spacing: 3) {
                        Text("全部 \(group.endedTotal) 个")
                        Image(.forward).font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(.subheadline).foregroundStyle(palette.ink2).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityHint("只看\(name)的会话")
            }
        }
        .padding(.horizontal, 4)
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
    let showsPlace: Bool
    /// 此刻要显示的结束请求（`DeliveryRequest.shownEnd`）。
    var end: Speech.Trip?
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services

    var body: some View {
        let session = item.state
        Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
            PiSessionRow(session: session, project: showsPlace ? item.project : nil, delivery: item.delivery, end: end, rename: item.rename, undelivered: item.undelivered(at: services.speech), style: .page).equatable()
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
