import CueStore
import SwiftUI

/// 会话列表的状态（手机搜索页的会话一栏、"更早"那一页）：搜索词、翻到第几页、读到的会话列表。
/// 两处都不按项目筛。`endedOnly`："更早"那一页只读已结束的（`PiSessionList.read`）。
/// 换搜索词或项目范围时回到第一页；历史按时间分页，滑到列表底再读下一页（`loadMore`）。
@Observable
final class AgentListModel {
    let endedOnly: Bool
    var list: PiSessionList?
    var query = "" { didSet { resetPaging() } }
    private(set) var limit = PiSessionList.pageSize

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    init(endedOnly: Bool = false) { self.endedOnly = endedOnly }

    var hasMore: Bool { list?.hasMore ?? false }

    func resetPaging() { limit = PiSessionList.pageSize }

    /// 按已读条数接着读一页（行在屏幕上时重跑：一页没填满屏幕就接着读）。
    func loadMore() {
        if let list { limit = list.loaded + PiSessionList.pageSize }
    }

    /// 列表空着、没在搜时的标题。
    static var noneTitle: String { String(localized: "还没有 Agent 会话") }
}

extension PiSessionList {
    /// "历史"按结束时间分的段（正在唤醒的读的时候就排掉了，`PiSessionList.earlier`）。
    var historyRuns: [TimeSection.Run<PiSessionListItem>] {
        TimeSection.split(ended, date: \.state.stateSince, now: .now)
    }
}

extension View {
    /// 读会话列表：随会话、投送请求、项目与目录绑定的变化重读，换搜索词时重新订阅；一并挂上行里的搜索高亮。
    func agentList(_ model: AgentListModel) -> some View { modifier(AgentListReader(model: model)) }
}

private struct AgentListReader: ViewModifier {
    @Bindable var model: AgentListModel
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content
            .environment(\.searchHighlight, model.query)
            .observing(
                services.store, id: PiSessionList.Key(filter: .init(text: model.query, project: nil), limit: model.limit, moment: services.speech),
                into: $model.list, onError: workspace.fail
            ) { [query = model.query, endedOnly = model.endedOnly, limit = model.limit, moment = services.speech] store in
                try PiSessionList.read(text: query, endedOnly: endedOnly, historyLimit: limit, at: moment, from: store)
            }
    }
}
