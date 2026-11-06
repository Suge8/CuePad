import CueStore
import SwiftUI

/// 会话列表（手机搜索页的会话一栏、三端"更早"那一页同一个，数据是两端共用的 `PiSessionList`）：最上面"已置顶"（绑在置顶任务上的），
/// 接着"现在"（按要你注意的先后：等你确认 → 出错 → 工作中 → 空闲），"历史"按结束时间分段、滑到底才读下一页。搜索词在 `model.query`，命中的字高亮。
/// "更早"那一页（`AgentListModel.earlierOnly`）只有历史，不写"历史"两字：页名就是"更早"。
/// 点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。长按（Mac 右键）是会话的菜单（`OpenSessionBeside` 与 `SessionActions`），手机上慢慢左滑可结束、重命名。`top`：列表最上面一行（搜索页的范围胶囊），随列表滚走。
struct SessionList<Top: View>: View {
    @Bindable var model: AgentListModel
    @ViewBuilder var top: Top
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    private static var margin: CGFloat { Spacing.page }

    var body: some View {
        List {
            // 每一行（卡片、分组标题、空态、读下一页的转圈）都不画底、不画分隔线：一处给全，漏了的那一行会在空态下面拖出一条孤线
            Group {
                if Top.self != EmptyView.self { top.listRowInsets(EdgeInsets()) }
                if let list = model.list { sessions(list) }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        // 每个会话一张卡片（`sessionCard`）：平铺列表，分组标题是普通的行（平铺列表的分组标题会吸顶）
        .listStyle(.plain)
        // 分组标题这类矮行不占系统给行的最小高度
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.horizontal, Self.margin)
        .safeAreaPadding(.top, Bars.contentGap)
        // 滚动条仍贴屏幕边与顶栏下沿，不随内容的边缩进
        .contentMargins(.horizontal, -Self.margin, for: .scrollIndicators)
        .contentMargins(.top, -Bars.contentGap, for: .scrollIndicators)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await services.syncNow() }
        #endif
        .agentList(model)
    }

    /// 会话列表。换搜索词时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）；同一筛选下会话进出、换状态才有动画。
    @ViewBuilder private func sessions(_ list: PiSessionList) -> some View {
        if list.isEmpty {
            empty
        } else {
            Group {
                if !list.pinned.isEmpty {
                    header { SectionHeader("已置顶").padding(.horizontal, Spacing.tight) }
                    ForEach(list.pinned) { row($0, in: list, end: list.ends[$0.id]) }
                }
                if !list.now.isEmpty {
                    header { SectionHeader("现在").padding(.horizontal, Spacing.tight) }
                    ForEach(list.now) { row($0, in: list, end: list.ends[$0.id]) }
                }
                ForEach(Array(list.historyRuns.enumerated()), id: \.element.section) { index, run in
                    header {
                        VStack(alignment: .leading, spacing: Spacing.group) {
                            if index == 0, !model.earlierOnly { SectionHeader("历史") }
                            SectionHeader(Dotted(run.section.title), level: .group)
                        }
                        .padding(.horizontal, Spacing.tight)
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
            .animation(Motion.nudge, value: (list.pinned + list.now).map(\.id))
            .animation(Motion.fade, value: (list.pinned + list.now).map(\.state.state))
            .animation(Motion.fade, value: (list.pinned + list.now + list.ended).map(\.delivery?.status))
            .animation(Motion.fade, value: list.ends)
        }
    }

    /// 分组标题：与卡片左缘对齐，上面多留一段把分组分开。
    private func header(@ViewBuilder _ title: () -> some View) -> some View {
        title()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: Spacing.block, leading: 0, bottom: Spacing.tight, trailing: 0))
    }

    /// 一张卡片：长按是会话的菜单，手机上慢慢左滑露出其中的结束与重命名。会话记录没有删除（会话文件在 Mac 上，归 Pi 管）。
    private func row(_ item: PiSessionListItem, in list: PiSessionList, end: Speech.Trip?) -> some View {
        let ending = end?.inTransit == true
        let row = SessionRow(item: item, showsPlace: list.showsPlace, end: end)
        // 行的边距挂在最外层：挂在自绘轻扫里面传不到列表上
        #if os(iOS)
        let card = row.rowSwipes(SessionActions.swipes(item.state, task: item.task, ending: ending, in: workspace), clipped: false)
        #else
        let card = row
        #endif
        return card
            .contextMenu {
                OpenSessionBeside(session: item.state)
                SessionActions(session: item.state, task: item.task, ending: ending)
            }
            .cardRow()
    }

    @ViewBuilder private var empty: some View {
        if model.searching {
            EmptyState.noMatch(model.query).padding(.top, Spacing.vacant)
        } else {
            EmptyState(mascot: .empty, title: .verbatim(AgentListModel.noneTitle), message: "在 Mac 的终端里开一个 Agent，或在这里开新会话", waitsForSync: true) {
                #if os(iOS)
                Button("新会话", icon: .add) { workspace.newSession = .init() }
                #else
                Button("新会话", icon: .add) { workspace.newSession() }
                #endif
            }
            .padding(.top, Spacing.vacant)
        }
    }
}

extension SessionList where Top == EmptyView {
    init(model: AgentListModel) { self.init(model: model) { EmptyView() } }
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
            PiSessionRow(session: session, project: showsPlace ? item.project : nil, delivery: item.delivery, end: end, rename: item.rename, task: item.task?.title, undelivered: item.undelivered(at: services.speech), style: .page).equatable()
                .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、回复" : "看近况、回复")
    }
}

private extension View {
    /// 会话卡片在列表里的一行：卡片之间留 8 点。
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: Spacing.tight, leading: 0, bottom: Spacing.tight, trailing: 0))
    }
}

/// "更早"那一页（`Route.earlier`，WORDS.md）：已结束与闲置的会话（`SessionDormancy`）按结束（闲置的是停下）时间分段（`AgentListModel.earlierOnly`），滑到底再读一页。三端同一页：
/// 手机从 Cue 页会话条底下"更早"那一格推入（`EarlierTile`，左边是系统返回）；Mac 与 iPad 宽屏点会话条上的"更早"在主区打开（`RailEarlier`）。
/// 在跑、等你的会话不在这里，它们在会话条上。
struct EarlierPage: View {
    @State private var model = AgentListModel(earlierOnly: true)

    var body: some View {
        #if os(iOS)
        SessionList(model: model).floatingHeader("更早")
        #else
        // 页名在窗口最顶那一排（主区的栏头）
        SessionList(model: model)
        #endif
    }
}
