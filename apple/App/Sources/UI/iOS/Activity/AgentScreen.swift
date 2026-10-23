#if os(iOS)
import CueStore
import SwiftUI

/// 会话页（iPhone 底部一排与宽屏侧栏的"会话"；Cue 面板的"全部会话"也换到这一页，项目页"⋯"里的"看这个项目的会话"设好项目范围再换到这里）：
/// 只回答"每个会话在做什么、现在到哪了、结果或卡点是什么"。顶栏中间两块玻璃（`ScopeQuota`）：项目范围（与任务页共用 `Workspace.projectScope`），
/// 与每个账号一颗的额度环——点环长出额度明细，两块并成一块面板（`GrowPanel`，同 Cue 的名牌）。搜会话在搜索页，这里不另放搜索框。
struct AgentScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var model = AgentListModel()

    private var filter: UUID? { workspace.scopedProject }

    var body: some View {
        SessionList(model: model, filter: filter)
            .refreshesQuota()
            .floatingHeader("会话", center: { ScopeQuota() }) {
                NewSessionButton(project: filter)
            }
    }
}

/// 会话页顶栏中间：项目范围与额度环各一块（还没有额度记录时只有项目范围）；点环长出额度明细。
private struct ScopeQuota: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = DebugHooks.preset.quotaOpen

    var body: some View {
        GrowPanel(open: $open, radius: FloatingHeaderLayout.height / 2, fills: false, separate: true) {
            HStack(spacing: 8) {
                ProjectScope().headerPiece()
                QuotaRings(open: open, height: FloatingHeaderLayout.height) { $open.grow(reduceMotion: reduceMotion) }.headerPiece()
            }
        } panel: {
            QuotaDetail().padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 18)
        }
    }
}

/// 会话列表（会话页、搜索页的会话一栏同一个，数据是两端共用的 `PiSessionList`）："现在"置顶（按要你注意的先后：等你确认 → 出错 → 工作中 → 空闲），
/// "历史"按结束时间分段、滑到底才读下一页。搜索词在 `model.query`，命中的字高亮。点开看近况、回复（历史会话看最后一轮，回复时 Mac 在后台恢复它）。
/// 在线会话长按或慢慢左滑可结束（确认后发给它所在的 Mac，对话留着）。`top`：列表最上面一行（搜索页的范围胶囊），随列表滚走。
struct SessionList<Top: View>: View {
    @Bindable var model: AgentListModel
    let filter: UUID?
    @ViewBuilder var top: Top
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    /// 最上面那一行的 id：换项目范围时滚回它。
    private static var topID: String { "top" }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear.frame(height: 0).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).id(Self.topID)
                if Top.self != EmptyView.self { top.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden) }
                if let list = model.list { sessions(list) }
            }
            // 每个会话一张卡片（`sessionCard`）：平铺列表、行不画底，分组标题是普通的行（平铺列表的分组标题会吸顶）
            .listStyle(.plain)
            // 顶上那一行只是滚回去的锚，不占系统给行的最小高度
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .contentMargins(.top, Bars.contentGap, for: .scrollContent)
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
            empty.listRowBackground(Color.clear)
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
                    Spinner(.regular).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                        .task(id: list.loaded) { model.loadMore() }
                }
            }
            .transaction(value: list.filter) { $0.animation = nil }
            .animation(Motion.snappy, value: list.now.map(\.id))
            .animation(HandOff.quick, value: list.now.map(\.state.state))
            .animation(HandOff.quick, value: (list.now + list.ended).map(\.delivery?.status))
            .animation(HandOff.quick, value: list.ends)
        }
    }

    /// 分组标题：与卡片左缘对齐，上面多留一段把分组分开。
    private func header(@ViewBuilder _ title: () -> some View) -> some View {
        title()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    /// 一张卡片：长按与慢慢左滑都有"结束会话"（在线的）与"重命名"（读得到的会话；Mac 够不着时置灰，会话页"⋯"里同一个说法）；快甩是切页（`rowSwipes`）。
    private func row(_ item: PiSessionListItem, in list: PiSessionList, end: Speech.Trip?) -> some View {
        let endable = item.state.canEnd && end != .sending
        let renamable = MacDelivery.canRename(item.state)
        // 结束不是删除：墨色，确认框里再说清后果；会话记录没有删除（会话文件在 Mac 上，归 Pi 管）
        let trailing = (endable ? [RowAction("结束会话", icon: .endSession) { model.confirmingEnd = item.state }] : [])
            + (renamable ? [RowAction("重命名", icon: .rename, tone: .quiet, enabled: services.reachesPiHost) { model.renaming = item.state }] : [])
        // 行的设置（底、分隔线、边距）挂在最外层：挂在自绘轻扫里面传不到列表上，列表退回系统默认的白底与分隔线
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
            EmptyState(mascot: .empty, title: AgentListModel.noneTitle(filter: filter), waitsForSync: true) {
                EmptyStateButton(title: "新会话", icon: .add, action: { workspace.newSession = .init(project: filter) })
            }
            .padding(.top, 40)
        } else {
            EmptyState(mascot: .empty, title: AgentListModel.noneTitle(filter: nil), message: "在 Mac 的终端里开一个 Agent，或在这里开新会话", waitsForSync: true) {
                EmptyStateButton(title: "新会话", icon: .add, action: { workspace.newSession = .init() })
            }
            .padding(.top, 40)
        }
    }
}

extension SessionList where Top == EmptyView {
    init(model: AgentListModel, filter: UUID?) { self.init(model: model, filter: filter) { EmptyView() } }
}

private struct NewSessionButton: View {
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
