#if os(iOS)
import CueStore
import SwiftUI

/// 会话列表（进展页的会话段、搜索页的会话一栏同一个，数据是两端共用的 `PiSessionList`）："现在"置顶（按要你注意的先后：等你确认 → 出错 → 工作中 → 空闲），
/// "历史"按结束时间分段、滑到底才读下一页。搜索词在 `model.query`，命中的字高亮。点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。
/// 在线会话长按或慢慢左滑可结束（确认后发给它所在的 Mac，对话留着）。`top`：列表最上面一行（搜索页的范围胶囊），随列表滚走。
struct SessionList<Top: View>: View {
    @Bindable var model: AgentListModel
    let filter: UUID?
    @ViewBuilder var top: Top
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    private static var margin: CGFloat { 16 }

    /// 最上面那一行的 id：换项目范围时滚回它。
    private static var topID: String { "top" }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // 每一行（卡片、分组标题、空态、读下一页的转圈）都不画底、不画分隔线：一处给全，漏了的那一行会在空态下面拖出一条孤线
                Group {
                    Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).id(Self.topID)
                    if Top.self != EmptyView.self { top.listRowInsets(EdgeInsets()) }
                    if let list = model.list { sessions(list) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            // 每个会话一张卡片（`sessionCard`）：平铺列表，分组标题是普通的行（平铺列表的分组标题会吸顶）
            .listStyle(.plain)
            // 顶上那一行只是滚回去的锚，不占系统给行的最小高度
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .safeAreaPadding(.horizontal, Self.margin)
            .safeAreaPadding(.top, Bars.contentGap)
            // 滚动条仍贴屏幕边与顶栏下沿，不随内容的边缩进
            .contentMargins(.horizontal, -Self.margin, for: .scrollIndicators)
            .contentMargins(.top, -Bars.contentGap, for: .scrollIndicators)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await services.syncNow() }
            // 换了项目范围：回到顶上，从这个项目的第一条看起
            .onChange(of: filter) { proxy.scrollTo(Self.topID, anchor: .top) }
        }
        .agentList(model, filter: filter)
    }

    /// 会话列表。换搜索词或项目时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）；同一筛选下会话进出、换状态才有动画。
    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        if list.isEmpty {
            empty
        } else {
            Group {
                if !list.now.isEmpty {
                    header { SectionTitle(text: "现在").padding(.horizontal, 4) }
                    ForEach(list.now) { row($0, in: list, end: list.ends[$0.id]) }
                }
                ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                    header {
                        VStack(alignment: .leading, spacing: 10) {
                            if index == 0 { SectionTitle(text: "历史") }
                            SectionLabel(text: Dotted(run.section.title))
                        }
                        .padding(.horizontal, 4)
                    }
                    ForEach(run.items) { row($0, in: list, end: list.ends[$0.id]) }
                }
                if model.hasMore {
                    // 滑到这里才读下一页。按已读条数重跑：读完一页它仍在屏幕上（一页没填满屏幕）时接着读
                    Spinner(.regular).frame(maxWidth: .infinity)
                        .task(id: list.loaded) { model.loadMore() }
                }
            }
            .transaction(value: list.filter) { $0.animation = nil }
            .animation(Motion.nudge, value: list.now.map(\.id))
            .animation(Motion.fade, value: list.now.map(\.state.state))
            .animation(Motion.fade, value: (list.now + list.ended).map(\.delivery?.status))
            .animation(Motion.fade, value: list.ends)
        }
    }

    /// 分组标题：与卡片左缘对齐，上面多留一段把分组分开。
    private func header(@ViewBuilder _ title: () -> some View) -> some View {
        title()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 4, trailing: 0))
    }

    /// 一张卡片：长按与慢慢左滑都有"结束会话"（在线的）与"重命名"（读得到的会话；Mac 够不着时置灰，会话近况页"⋯"里同一个说法）（`rowSwipes`）。
    private func row(_ item: PiSessionListItem, in list: PiSessionList, end: Speech.Trip?) -> some View {
        let endable = item.state.canEnd && end?.inTransit != true
        let renamable = MacDelivery.canRename(item.state)
        // 结束不是删除：墨色，确认框里再说清后果；会话记录没有删除（会话文件在 Mac 上，归 Pi 管）
        let trailing = (endable ? [RowAction("结束会话", icon: .endSession) { model.confirmingEnd = item.state }] : [])
            + (renamable ? [RowAction("重命名", icon: .rename, tone: .quiet, enabled: services.reachesPiHost) { model.renaming = item.state }] : [])
        // 行的边距挂在最外层：挂在自绘轻扫里面传不到列表上
        return SessionRow(item: item, showsPlace: list.showsPlace, end: end)
            .rowSwipes(RowSwipes(trailing: trailing), clipped: false)
            .contextMenu {
                MarkUnreadButton(session: item.state)
                RowActionButtons(actions: trailing.reversed())
            }
            .cardRow()
    }

    @ViewBuilder private var empty: some View {
        if model.searching {
            EmptyState.noMatch(model.query).padding(.top, 40)
        } else if let filter {
            EmptyState(mascot: .empty, title: .verbatim(AgentListModel.noneTitle(filter: filter)), waitsForSync: true) {
                EmptyStateButton(title: "新会话", icon: .add, action: { workspace.newSession = .init(project: filter) })
            }
            .padding(.top, 40)
        } else {
            EmptyState(mascot: .empty, title: .verbatim(AgentListModel.noneTitle(filter: nil)), message: "在 Mac 的终端里开一个 Agent，或在这里开新会话", waitsForSync: true) {
                EmptyStateButton(title: "新会话", icon: .add, action: { workspace.newSession = .init() })
            }
            .padding(.top, 40)
        }
    }
}

extension SessionList where Top == EmptyView {
    init(model: AgentListModel, filter: UUID?) { self.init(model: model, filter: filter) { EmptyView() } }
}

/// "新会话"：在 `project` 里开（顶栏右边的那一个操作）。
struct NewSessionButton: View {
    let project: UUID?

    @Environment(Workspace.self) private var workspace
    var body: some View {
        Button("新会话", icon: .add) { workspace.newSession = .init(project: project) }
            .accessibilityHint("让 Mac 开一个 Agent 会话")
    }
}

/// 一个会话（`PiSessionRow`）点开它的会话页；已结束的整行更淡。
private struct SessionRow: View {
    let item: PiSessionListItem
    let showsPlace: Bool
    /// 此刻要显示的结束请求（`DeliveryRequest.shownEnd`）。
    var end: Speech.Trip?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let session = item.state
        Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: {
            PiSessionRow(session: session, project: showsPlace ? item.project : nil, delivery: item.delivery, end: end, rename: item.rename, undelivered: item.undelivered(at: services.speech), handoff: item.handoff, style: .page).equatable()
                .contentShape(.rect(cornerRadius: SessionCard.radius))
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、回复" : "看近况、回复")
    }
}

private extension View {
    /// 会话卡片在列表里的一行：卡片之间留 8 点。
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}
#endif
