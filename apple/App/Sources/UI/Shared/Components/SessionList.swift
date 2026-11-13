#if os(iOS)
import CueStore
import SwiftUI

/// `top`：列表最上面一行（搜索页的范围胶囊），随列表滚走。
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
        .contentMargins(.horizontal, -Self.margin, for: .scrollIndicators)
        .contentMargins(.top, -Bars.contentGap, for: .scrollIndicators)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await services.syncNow() }
        .agentList(model)
    }

    /// 换搜索词时整段换掉、不做动画（逐行挪动会让新旧两批字叠在一起）；同一筛选下会话进出、换状态才有动画。
    @ViewBuilder private func sessions(_ list: SessionListData) -> some View {
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
                            if index == 0, !model.endedOnly { SectionHeader("历史") }
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

    private func header(@ViewBuilder _ title: () -> some View) -> some View {
        title()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: Spacing.block, leading: 0, bottom: Spacing.tight, trailing: 0))
    }

    /// 会话记录没有删除（会话文件在 Mac 上，归 Pi 管）。
    private func row(_ item: SessionListItem, in list: SessionListData, end: Speech.Trip?) -> some View {
        let ending = end?.inTransit == true
        // 行的边距挂在最外层：挂在自绘轻扫里面传不到列表上
        return SessionListRow(item: item, showsPlace: list.showsPlace, end: end)
            .rowSwipes(SessionActions.swipes(item.state, task: item.task, ending: ending, in: workspace), clipped: false)
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
            EmptyState(mascot: .empty, title: .verbatim(AgentListModel.noneTitle), message: "在这里开新会话；Mac 上接入的 Agent，它的会话记录也会出现在这里", waitsForSync: true) {
                Button("新会话", icon: .add) { workspace.openNewSession() }
            }
            .padding(.top, Spacing.vacant)
        }
    }
}

extension SessionList where Top == EmptyView {
    init(model: AgentListModel) { self.init(model: model) { EmptyView() } }
}

private struct SessionListRow: View {
    let item: SessionListItem
    let showsPlace: Bool
    var end: Speech.Trip?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let session = item.state
        Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: {
            SessionRow(session: session, project: showsPlace ? item.project : nil, delivery: item.delivery, end: end, rename: item.rename, task: item.task?.title, undelivered: item.undelivered(at: services.speech), style: .page).equatable()
                .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint(session.state == .known(.ended) ? "看最后一轮、回复" : "看近况、回复")
    }
}

private extension View {
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: Spacing.tight, leading: 0, bottom: Spacing.tight, trailing: 0))
    }
}

/// 项目页的"更早"是另一样（没在墙上的旧灵感），两处不混。
struct EarlierPage: View {
    @State private var model = AgentListModel(endedOnly: true)

    var body: some View {
        SessionList(model: model).floatingHeader("历史")
    }
}
#endif
