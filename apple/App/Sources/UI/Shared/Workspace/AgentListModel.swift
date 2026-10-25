import CueStore
import SwiftUI

/// 会话页的状态（iOS 与 Mac 同一份，iOS 的搜索页会话一栏也是它）：搜索词、翻到第几页、读到的会话列表，以及正在确认结束或改名的会话。
/// 项目范围不在这里：会话页读 `Workspace.projectScope`（搜索页不筛），交给 `.agentList`。
/// 换搜索词或项目范围时回到第一页；历史按时间分页，滑到列表底再读下一页（`loadMore`）。
@Observable
final class AgentListModel {
    var list: PiSessionList?
    var query = "" { didSet { resetPaging() } }
    private(set) var limit = PiSessionList.pageSize
    var confirmingEnd: PiSessionState?
    var renaming: PiSessionState?

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var hasMore: Bool { list?.hasMore ?? false }

    func resetPaging() { limit = PiSessionList.pageSize }

    /// 按已读条数接着读一页（行在屏幕上时重跑：一页没填满屏幕就接着读）。
    func loadMore() {
        if let list { limit = list.loaded + PiSessionList.pageSize }
    }

    /// 列表空着、没在搜时的标题（两端同一句；下面的说明与按钮各端自己给）；`filter` 是此刻的项目范围。
    static func noneTitle(filter: UUID?) -> String {
        filter == nil ? String(localized: "还没有 Agent 会话") : String(localized: "这个项目还没有 Agent 会话")
    }
}

extension PiSessionList {
    /// "历史"按结束时间分的段；正在唤醒的列在"现在"，这里不再列。
    var historyRuns: [TimeSection.Run<PiSessionListItem>] {
        let current = Set(now.map(\.id))
        return TimeSection.split(ended.filter { !current.contains($0.id) }, date: \.state.stateSince, now: .now)
    }
}

extension View {
    /// 读会话列表（`filter` 是此刻的项目范围）：随会话、投送请求、项目与目录绑定的变化重读，换搜索词或筛选时重新订阅；
    /// 一并挂上改名与结束会话的确认、行里的搜索高亮。
    func agentList(_ model: AgentListModel, filter: UUID?) -> some View { modifier(AgentListReader(model: model, filter: filter)) }
}

private struct AgentListReader: ViewModifier {
    @Bindable var model: AgentListModel
    let filter: UUID?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content
            .environment(\.searchHighlight, model.query)
            .renameSession($model.renaming)
            .endSession($model.confirmingEnd)
            .onChange(of: filter) { model.resetPaging() }
            .observing(
                services.store, id: PiSessionList.Key(filter: .init(text: model.query, project: filter), limit: model.limit, moment: services.speech),
                into: $model.list, onError: workspace.fail
            ) { [query = model.query, limit = model.limit, moment = services.speech] store in
                try PiSessionList.read(text: query, project: filter, historyLimit: limit, at: moment, from: store)
            }
    }
}
