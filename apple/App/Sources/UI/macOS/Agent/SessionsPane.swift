#if os(macOS)
import CueStore
import SwiftUI

/// 进展页的会话段（`ProgressPage`）：全部会话，在线的在上（现在）、历史在下，只看项目范围里的（`Workspace.scopedProject`，与看板一段共用）。
/// 页里不另起一排：范围、额度环与新会话在工具栏那一排（`ProgressPage` 的头注释）；搜索框是列表的第一行，随列表滚走。
/// 列表与行同手机（`PiSessionList`、`PiSessionRow`），点行在内容区打开会话页；在线会话右键可结束（确认后发给它所在的 Mac，对话留着）。
/// 这台 Mac 检测到 Agent 却一家都没接入时，最上面是接入小卡（`ConnectAgents`）：没接入时本机的会话在这里看不到。
struct SessionsPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = AgentListModel()

    private var filter: UUID? { workspace.scopedProject }

    /// 列表的宽度：一行读得完，不至于横跨整个大窗口。
    private static let width: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { column }
            .onChange(of: filter) { proxy.scrollTo(Self.top, anchor: .top) }
        }
        // 让在安全区里（同看板一段）：列表照样滚到工具栏后面
        .safeAreaPadding(.top, Bars.contentGap)
        .background(palette.desk)
        .agentList(model, filter: filter)
    }

    private static let top = "top"

    private var column: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            searchField.id(Self.top).padding(.bottom, 12)
            ConnectAgents().padding(.bottom, 12)
            if let list = model.list { sessions(list) }
        }
        .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.pageTop)
        .frame(maxWidth: Self.width)
        .frame(maxWidth: .infinity)
    }

    private var searchField: some View {
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
        .background(palette.fill, in: .capsule)
    }

    private var searchPrompt: String {
        workspace.catalog?.project(filter).map { String(localized: "搜 \($0.shownName) 的会话") } ?? String(localized: "搜会话、目录、说过的话")
    }

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

    private func title(_ text: LocalizedStringResource) -> some View {
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
        let endable = session.canEnd && end?.inTransit != true
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
            EmptyState(mascot: .empty, title: .verbatim(AgentListModel.noneTitle(filter: filter)),
                       message: "在终端里开一个 Agent，或点右上角开新会话（⌥⌘N）", waitsForSync: true) { EmptyView() }
        }
    }
}

/// 接入 Agent 的小卡：这台 Mac 检测到 Agent、一家都没接入、桥上也没有会话时才有（没接入时本机的会话在这里看不到，列表空着时它就是如实的空态，不再叠吉祥物）。
/// 开头是检测到的那几家的标志（不套方块底），标题直说检测到了谁，下面一句说接入后能看到什么；"接入"打开接入面板
/// （`SetupPanel`，检测到还没接入的几家一键接入；Cue 没启用时同一下启用它）。接入以后它自己消失，别的 Mac 上的会话照样列在下面。
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
            let found = AgentKind.allCases.filter { services.agents.status($0) != nil }
            HStack(alignment: .center, spacing: 14) {
                HStack(spacing: -6) {
                    ForEach(found, id: \.self) { kind in
                        kind.mark.image.font(.system(size: 15)).foregroundStyle(palette.ink)
                            .frame(width: 30, height: 30).background(palette.desk, in: .circle)
                            .overlay(Circle().strokeBorder(palette.paper, lineWidth: 2))
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("这台 Mac 上有 \(Self.names(found))").font(Typography.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
                    Text("接入后，在终端和桌面版里开的会话也列在这里，能看进展、回话").font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { workspace.showsSetup = true } label: {
                    Text("接入").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.onFill)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
            }
            .sessionCard()
            .help("接入以后 CuePad 往它的配置目录写技能（Claude Code、Codex 另写钩子），在设置里关掉即删除")
        }
    }

    /// "Pi、Claude Code 和 Codex"："和"两边与西文名之间留空格（系统的列表格式在中文里不留）。
    private static func names(_ found: [AgentKind]) -> String {
        let all = found.map(\.name)
        guard all.count > 1, let last = all.last else { return all.first ?? "" }
        let head = all.dropLast().joined(separator: String(localized: "、"))
        return String(localized: "\(head) 和 \(last)")
    }
}
#endif
