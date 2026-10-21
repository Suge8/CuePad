#if os(macOS)
import CueStore
import SwiftUI

/// 会话页（侧栏的"会话"进来）：没有页标题。项目范围在窗口最顶那一排（工具栏的 `ScopeSlot`，与任务页共用 `Workspace.projectScope`）；
/// 页里自己顶上一排（列表滚到它后面）是搜索、额度环（`QuotaRings`，同手机；点它从环下长出明细的气泡 `QuotaDetail`，点外面或 Esc 收回）与新会话
/// （右上"⋯"里同一下，还有接入 Agent）：它们的状态归这一页，不进工具栏（工具栏只放 Workspace 里已有的状态，规矩在 `ScopeSlot`）。
/// 列表与行同手机（`PiSessionList`、`PiSessionRow`），点行在内容区打开会话页；在线会话右键可结束（确认后发给它所在的 Mac，对话留着）。
/// 这台 Mac 检测到 Agent 却一家都没接入时，最上面是接入小卡（`ConnectAgents`）：没接入时本机的会话在这里看不到。
struct AgentPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = AgentListModel()
    /// 额度明细的气泡开着；收起的时刻（按在环上收起的，松开时不再打开，`PressPoint.reopens`）。
    @State private var quotaOpen = DebugHooks.preset.quotaOpen
    @State private var quotaClosed: ContinuousClock.Instant?

    private var filter: UUID? { workspace.scopedProject }

    /// 列表的宽度：一行读得完，不至于横跨整个大窗口。
    private static let width: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { column }
            .onChange(of: filter) { proxy.scrollTo(Self.top, anchor: .top) }
        }
        // 顶上那一排钉在工具栏下、浮在列表上，列表滚到它后面（`Bars`）：排在安全区里，滚动区上沿不加内边距
        .safeAreaInset(edge: .top, spacing: Bars.contentGap) {
            topRow.frame(maxWidth: Self.width - Spacing.page * 2)
                .frame(minHeight: Spacing.toolbarControl)
                .padding(.horizontal, Spacing.page).padding(.top, Bars.contentGap)
        }
        .background(palette.desk)
        .agentList(model, filter: filter)
        .refreshesQuota()
        .onChange(of: quotaOpen) { _, open in if !open { quotaClosed = .now } }
    }

    private func toggleQuota() {
        quotaOpen = !quotaOpen && !PressPoint.reopens(closedAt: quotaClosed)
    }

    private static let top = "top"

    private var column: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            Color.clear.frame(height: 0).id(Self.top)
            ConnectAgents().padding(.bottom, 12)
            if let list = model.list { sessions(list) }
        }
        .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.pageTop)
        .frame(maxWidth: Self.width)
        .frame(maxWidth: .infinity)
    }

    /// 顶上一排：搜索，右边额度环与新会话。
    private var topRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(.search).foregroundStyle(palette.ink3).accessibilityHidden(true)
                TextField(searchPrompt, text: $model.query, palette: palette).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(.clear).frame(width: 24, height: 24).contentShape(.circle)
                    }
                    .buttonStyle(PressStyle(.button)).foregroundStyle(palette.ink3)
                    .accessibilityLabel("清除")
                }
            }
            .font(Typography.body)
            .padding(.horizontal, 14).frame(height: 36)
            .glass(in: .capsule)
            QuotaRings(open: quotaOpen, height: Spacing.toolbarControl, action: toggleQuota)
                .glass(in: .capsule, interactive: true)
                .bubble(isPresented: $quotaOpen) { QuotaDetail().padding(16) }
            NewSessionButton(showing: Bindable(workspace).showsNewSession)
        }
    }

    private var searchPrompt: String {
        workspace.catalog?.project(filter).map { "搜 \($0.name) 的会话" } ?? Self.prompt
    }

    private static let prompt = "搜会话、目录、说过的话"

    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        if list.isEmpty {
            if !ConnectAgents.needed(services) { empty.padding(.top, 60) }
        } else {
            if !list.now.isEmpty {
                title("现在")
                cards { ForEach(list.now) { row($0, in: list, end: list.ends[$0.id]) } }
            }
            ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                if index == 0 { title("历史") }
                SectionLabel(text: Dotted(run.section.title))
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

    private func title(_ text: String) -> some View {
        SectionTitle(text: text).padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 8)
    }

    /// 一组会话卡片（每张自带卡片面，`sessionCard`）。组里的卡片也懒加载：历史的"更早"一组可能有几千张，普通 VStack 会把它们全建出来
    /// （真实库三千条历史滚到底时内存涨到 1.4GB、每读一页卡一两秒）。
    private func cards(@ViewBuilder _ rows: () -> some View) -> some View {
        LazyVStack(spacing: 8) { rows() }
    }

    /// 看全部项目时卡上放所在项目的图标（`PiSessionList.showsPlace`）。
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
        if model.searching {
            EmptyState.noMatch(model.query)
        } else {
            EmptyState(mascot: .empty, title: AgentListModel.noneTitle(filter: filter),
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
