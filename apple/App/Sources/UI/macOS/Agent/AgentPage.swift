#if os(macOS)
import CueStore
import SwiftUI

/// 会话页（侧栏的"会话"进来）：没有页标题（侧栏那块选中就说了在哪），最上面就是一排（按项目筛、搜索、新会话），下面是订阅额度的总览（`QuotaStrip`，没有额度记录时没有）。
/// 不筛也不搜时按项目分组（`PiSessionList.Group`）：组头是项目图标与名字、几个在线，下面先是它在线的会话（按要你注意的先后：等你确认 → 出错 → 工作中 → 空闲），
/// 再是最近结束的几条；结束的更多时组头右边"全部 N 个"按这个项目筛。没有项目的会话归默认项目那一组。一眼看出哪个项目在跑什么，不必读每张卡的所在。
/// 按项目筛着或在搜时是"现在"与按结束时间分段的"历史"（`PiHistorySection`），读到底再接一页；只有搜索的平铺结果在卡上写所在。
/// 行与手机同一种（`PiSessionRow`），点行在内容区打开会话页；在线会话右键可结束（确认后发给它所在的 Mac，对话留着）。
/// 这台 Mac 检测到 Agent 却一家都没接入时，最上面是接入小卡（`ConnectAgents`）：没接入时本机的会话在这里看不到。
struct AgentPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = AgentListModel()
    @State private var filter: UUID?

    /// 列表的宽度：一行读得完，不至于横跨整个大窗口。
    private static let width: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { column }
            // 组头的"全部"在页中间换筛选：换完回到顶上，从这个项目的第一条看起
            .onChange(of: filter) { proxy.scrollTo(Self.top, anchor: .top) }
        }
        .background(palette.desk)
        .agentList(model, filter: filter)
        .refreshesQuota()
    }

    private static let top = "top"

    private var column: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            topRow.padding(.bottom, 16).id(Self.top)
            QuotaStrip().padding(.horizontal, 4).padding(.bottom, 12)
            ConnectAgents().padding(.bottom, 12)
            if let list = model.list { sessions(list) }
        }
        .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.pageTop)
        .frame(maxWidth: Self.width)
        .frame(maxWidth: .infinity)
    }

    /// 顶上一排：左边按项目筛（全部、在 Mac 上绑了文件夹的项目与默认项目），中间搜索，右边新会话。
    private var topRow: some View {
        HStack(spacing: 10) {
            filterMenu
            HStack(spacing: 6) {
                Image(.search).foregroundStyle(palette.ink3).accessibilityHidden(true)
                TextField(searchPrompt, text: $model.query, palette: palette).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button("清除", icon: .clear) { model.query = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette.ink3)
                }
            }
            .font(Typography.body)
            .padding(.horizontal, 14).frame(height: 36)
            .glass(in: .capsule)
            NewSessionButton(showing: Bindable(workspace).showsNewSession)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .glass(in: .circle, interactive: true, ink: .clear)
        }
    }

    private var searchPrompt: String {
        workspace.catalog?.project(filter).map { "搜 \($0.name) 的会话" } ?? Self.prompt
    }

    private static let prompt = "搜会话、目录、说过的话"

    private var filterMenu: some View {
        let projects = model.filterable(in: workspace.catalog, current: filter)
        let current = workspace.catalog?.project(filter)
        return Menu {
            Picker("按项目看", selection: $filter) {
                Label("全部", icon: .all).tag(UUID?.none)
                ForEach(projects) { project in
                    Label { Text(project.name) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if filter == nil { Image(.filter) } else { ProjectGlyph(project: current, size: 13) }
                Text(current?.name ?? "全部").lineLimit(1)
            }
            .font(Typography.toolbarLabel).foregroundStyle(palette.ink2)
            .padding(.horizontal, 12).frame(height: 36)
            .glass(in: .capsule, interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(current.map { "按项目看：\($0.name)" } ?? "按项目看")
    }

    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        if list.isEmpty {
            if !ConnectAgents.needed(services) { empty.padding(.top, 60) }
        } else if case .grouped(let groups) = list.history {
            ForEach(groups) { group in
                header(group)
                cards {
                    nowRows(group.now, in: list)
                    ForEach(group.ended) { row($0, in: list, end: nil) }
                }
            }
        } else {
            if !list.now.isEmpty {
                title("现在")
                cards { nowRows(list.now, in: list) }
            }
            ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                if index == 0 { title("历史") }
                Text(run.section.title).font(Typography.label).foregroundStyle(palette.ink3)
                    .padding(.horizontal, 4).padding(.top, index == 0 ? 0 : 14).padding(.bottom, 6)
                cards { ForEach(run.items) { row($0, in: list, end: nil) } }
            }
            if model.hasMore {
                // 滑到这里才读下一页
                Spinner(.small).frame(maxWidth: .infinity).padding(16)
                    .task(id: list.loaded) { model.loadMore() }
            }
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
                if model.reloadOpen { ForEach(items) { row($0, in: list, end: list.ends[$0.id]) } }
            }
        }
    }

    /// 一组的组头：项目图标与名字、几个在线；结束的还有没列出来的时，右边"全部 N 个"按这个项目筛。
    private func header(_ group: PiSessionList.Group) -> some View {
        let project = workspace.catalog?.project(group.id)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProjectGlyph(project: project, size: 14)
            Text(project?.name ?? "").font(Typography.sectionTitle).foregroundStyle(palette.ink).lineLimit(1)
            if !group.now.isEmpty {
                Text("\(group.now.count) 个在线").font(Typography.sectionCount).foregroundStyle(palette.ink3)
            }
            Spacer(minLength: 8)
            if group.hasMore {
                Button { filter = group.id } label: {
                    HStack(spacing: 3) {
                        Text("全部 \(group.endedTotal) 个")
                        Image(.forward).font(Typography.meta.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(Typography.secondary).foregroundStyle(palette.ink2).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .help("只看\(project?.name ?? "")的会话")
            }
        }
        .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Typography.sectionTitle).foregroundStyle(palette.ink)
            .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// 一组会话卡片（每张自带卡片面，`sessionCard`）。组里的卡片也懒加载：历史的"更早"一组可能有几千张，普通 VStack 会把它们全建出来
    /// （真实库三千条历史滚到底时内存涨到 1.4GB、每读一页卡一两秒）。
    private func cards(@ViewBuilder _ rows: () -> some View) -> some View {
        LazyVStack(spacing: 8) { rows() }
    }

    /// 所在只在搜索的平铺结果里写在卡上（`PiSessionList.showsPlace`）：分组时组头、筛着时筛选已经说了。
    private func row(_ item: PiSessionListItem, in list: PiSessionList, end: Speech.Trip?) -> some View {
        let session = item.state
        let endable = session.canEnd && end != .sending
        return PiSessionRow(session: session, project: list.showsPlace ? item.project : nil, delivery: item.delivery, end: end, rename: item.rename, undelivered: item.undelivered(at: services.speech), style: .page).equatable()
            .sessionLink(session.sessionID, press: .card)
            .contextMenu {
                SessionMenu(session: session, rename: { model.renaming = session }, end: endable ? { model.confirmingEnd = session } : nil)
            }
    }

    @ViewBuilder private var empty: some View {
        let empty = model.empty(filter: filter)
        switch empty {
        case .noMatch(let query):
            EmptyState.noMatch(query)
        case .none:
            EmptyState(mascot: .empty, title: empty.noneTitle,
                       message: "在终端里开一个 Agent，或点右上角开新会话（⌥⌘N）", waitsForSync: true) { EmptyView() }
        }
    }
}

/// 接入 Agent 的小卡：这台 Mac 检测到 Agent、一家都没接入、桥上也没有会话时才有（没接入时本机的会话在这一页看不到，列表空着时它就是如实的空态，不再叠吉祥物）。
/// 一个图标、一句话说接入了双向能做什么，右边"接入"打开接入面板（`SetupPanel`，检测到还没接入的几家，一键接入；Cue 没启用时同一下启用它）；别的 Mac 上的会话照样列在下面。
private struct ConnectAgents: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    /// 检测到 Agent、一家都没接入、桥上也没有会话。
    static func needed(_ services: AppServices) -> Bool {
        let agents = services.agents
        return AgentKind.allCases.contains { agents.status($0) != nil } && !AgentKind.allCases.contains { agents.status($0)?.isConnected == true }
            && services.pi.slots.isEmpty
    }

    var body: some View {
        if Self.needed(services) {
            HStack(alignment: .center, spacing: 12) {
                Image(.extensionNote).font(.system(size: 15)).foregroundStyle(palette.ink2)
                    .frame(width: 32, height: 32).background(palette.fill, in: .rect(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("接入 Agent").font(Typography.bodyStrong).foregroundStyle(palette.ink)
                    Text("终端和桌面版里的会话与历史也看得到").font(Typography.secondary).foregroundStyle(palette.ink2)
                }
                Spacer(minLength: 8)
                Button { workspace.showsSetup = true } label: {
                    Text("接入").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.onFill)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
            }
            .sessionCard()
            .help("接入 Pi、Claude Code、Codex 或 OpenCode：在终端和桌面版里开的会话与历史也出现在这里，在 Mac 和手机上看进展、发话、回答提问。CuePad 往它的配置目录写技能（Claude Code、Codex 另写钩子），在设置里关掉即删除。")
        }
    }
}
#endif
