#if os(macOS)
import CueStore
import SwiftUI

/// Agent 页（侧栏"全部会话"进来）：与手机的 Agent 页同构——顶上一排（按项目筛、搜索、新会话），"现在"是没结束的会话、
/// 按要你注意的先后（等你确认 → 出错 → 工作中 → 空闲），"历史"是已结束的、按结束时间分段（`PiHistorySection`），
/// 读到底再接一页。行与手机同一种（`PiSessionRow`），点行在内容区打开会话页；在线会话右键可结束（确认后发给它所在的 Mac，对话留着）。
struct AgentPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var list: PiSessionList?
    @State private var query = ""
    @State private var filter: UUID?
    @State private var limit = PiSessionList.pageSize
    @State private var starting = false
    @State private var confirmingEnd: PiSessionState?
    @State private var renaming: PiSessionState?
    @State private var reloadOpen = false

    /// 列表的宽度：一行读得完，不至于横跨整个大窗口。
    private static let width: CGFloat = 720

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                heading.padding(.bottom, 18)
                topRow.padding(.bottom, 16)
                if let list { sessions(list) }
            }
            .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, 96)
            .frame(maxWidth: Self.width)
            .frame(maxWidth: .infinity)
        }
        .fadesUnderBars()
        .background(palette.desk)
        .environment(\.searchHighlight, query)
        .onChange(of: query) { limit = PiSessionList.pageSize }
        .onChange(of: filter) { limit = PiSessionList.pageSize }
        .renameSession($renaming)
        .confirmationDialog("结束这个会话？", isPresented: Binding { confirmingEnd != nil } set: { if !$0 { confirmingEnd = nil } },
                            titleVisibility: .visible, presenting: confirmingEnd) { session in
            Button("结束会话", role: .destructive) { Task { await workspace.end(session) } }
        } message: { _ in
            Text("对话会保留，再给它发消息会在后台恢复")
        }
        .observing(services.store, [.piSessionStates, .deliveryRequests, .projects, .directoryBindings],
                   id: PiSessionList.Key(filter: .init(text: query, project: filter), limit: limit),
                   into: $list, onError: workspace.fail) { [query, filter, limit] store in
            try PiSessionList.read(text: query, project: filter, historyLimit: limit, from: store)
        }
    }

    /// 页标题：与项目页、归档、回收站同一层级；下面一行是此刻筛出的在线与历史各几个。
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent").font(Typography.pageTitle).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            if let list {
                Text(Dotted("\(list.now.count) 个在线", "\(list.total) 个历史")).font(Typography.meta).foregroundStyle(palette.ink3)
                    .monospacedDigit()
            }
        }
    }

    /// 顶上一排：左边按项目筛（全部 + 在 Mac 上绑了文件夹的项目），中间搜索，右边新会话。
    private var topRow: some View {
        HStack(spacing: 10) {
            filterMenu
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
                TextField(searchPrompt, text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button("清除", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette.ink3)
                }
            }
            .font(Typography.body)
            .padding(.horizontal, 14).frame(height: 36)
            .glass(in: .capsule)
            NewSessionButton(showing: $starting)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .glass(in: .circle, interactive: true)
        }
    }

    private var searchPrompt: String {
        workspace.catalog?.project(filter).map { "搜 \($0.name) 的会话" } ?? "搜会话、目录、说过的话"
    }

    private var filterMenu: some View {
        let projects = (workspace.catalog?.projects ?? []).filter { list?.projects.contains($0.id) == true || $0.id == filter }
        let current = workspace.catalog?.project(filter)
        return Menu {
            Picker("按项目看", selection: $filter) {
                Label("全部", systemImage: "square.stack").tag(UUID?.none)
                ForEach(projects) { project in
                    Label { Text(project.name) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let current { ProjectGlyph(project: current, size: 13) } else { Image(systemName: "line.3.horizontal.decrease") }
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
        let filtered = list.filter.project != nil
        if list.isEmpty {
            empty.padding(.top, 60)
        } else {
            if !list.now.isEmpty {
                title("现在")
                card {
                    ForEach(PiNowRow.rows(list.now, state: \.state)) { nowRow in
                        switch nowRow {
                        case .session(let item): row(item, filtered: filtered, end: list.ends[item.id])
                        case .reload(let items):
                            PiReloadFold(count: items.count, expanded: $reloadOpen, style: .page)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                            if reloadOpen { ForEach(items) { row($0, filtered: filtered, end: list.ends[$0.id]) } }
                        }
                    }
                }
            }
            let runs = PiHistorySection.split(list.ended, date: \.state.stateSince, now: .now)
            ForEach(Array(runs.enumerated()), id: \.element.section) { index, run in
                if index == 0 { title("历史") }
                Text(run.section.title).font(Typography.label).foregroundStyle(palette.ink3)
                    .padding(.horizontal, 4).padding(.top, index == 0 ? 0 : 14).padding(.bottom, 6)
                card { ForEach(run.items) { row($0, filtered: filtered, end: nil) } }
            }
            if list.loaded < list.total {
                // 滑到这里才读下一页
                Spinner(.small).frame(maxWidth: .infinity).padding(16)
                    .task(id: list.loaded) { limit = list.loaded + PiSessionList.pageSize }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Typography.sectionTitle).foregroundStyle(palette.ink)
            .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// 一组行垫一张纸。组里的行也懒加载：历史的"更早"一组可能有几千行，普通 VStack 会把它们全建出来
    /// （真实库三千条历史滚到底时内存涨到 1.4GB、每读一页卡一两秒）。
    private func card(@ViewBuilder _ rows: () -> some View) -> some View {
        LazyVStack(spacing: 0) { rows() }
            .padding(4)
            .paper(radius: 14)
    }

    private func row(_ item: PiSessionListItem, filtered: Bool, end: DeliveryRequest?) -> some View {
        let session = item.state
        let endable = MacDelivery.canEnd(session) && end?.isOpen != true
        return PiSessionRow(session: session, project: filtered ? nil : item.project, delivery: item.delivery, end: end, rename: item.rename, undelivered: item.undelivered, style: .page)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sessionLink(session.sessionID)
            .contextMenu {
                MarkUnreadButton(session: session)
                if MacDelivery.canRename(session) {
                    Button("重命名…", systemImage: "pencil") { renaming = session }
                }
                if endable {
                    Button("结束会话", systemImage: "stop.circle", role: .destructive) { confirmingEnd = session }
                }
            }
    }

    @ViewBuilder private var empty: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyState.noMatch(query)
        } else if let filter, let project = workspace.catalog?.project(filter), !workspace.hasFolder(filter) {
            EmptyState(mascot: .empty, title: "还没绑定文件夹", message: "绑定后，在那个文件夹里跑的 Agent 会话会出现在这里") {
                FolderGuideReader { ProjectFolderGuide(project: project, guide: $0) }
            }
        } else {
            EmptyState(mascot: .empty, title: filter == nil ? "还没有 Agent 会话" : "这个项目还没有 Agent 会话",
                       message: "在终端运行 pi，或点右上角开一个新会话") { EmptyView() }
        }
    }
}
#endif
