import CueStore
import SwiftUI

/// Agent 页的状态（iOS 与 Mac 同一份，iOS 的搜索页会话一栏也是它）：搜索词、翻到第几页、读到的会话列表，以及正在确认结束或改名的会话。
/// 项目筛选不在这里：页面自己存（只留在那一页上），交给 `.agentList`。
/// 换搜索词或筛选时回到第一页；历史按页读，滑到列表底再读下一页（`loadMore`）。
@Observable
final class AgentListModel {
    var list: PiSessionList?
    var query = "" { didSet { resetPaging() } }
    private(set) var limit = PiSessionList.pageSize
    var confirmingEnd: PiSessionState?
    var renaming: PiSessionState?
    var reloadOpen = false

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 还有没读的历史。
    var hasMore: Bool { list.map { $0.loaded < $0.total } ?? false }

    func resetPaging() { limit = PiSessionList.pageSize }

    /// 按已读条数接着读一页（行在屏幕上时重跑：一页没填满屏幕就接着读）。
    func loadMore() {
        if let list { limit = list.loaded + PiSessionList.pageSize }
    }

    /// 能按它筛的项目：在 Mac 上绑了文件夹的（会话按工作目录归入项目），加上此刻筛着的。
    func filterable(in catalog: ProjectCatalog?, current: UUID?) -> [Project] {
        (catalog?.projects ?? []).filter { list?.projects.contains($0.id) == true || $0.id == current }
    }

    enum Empty: Equatable {
        case noMatch(String)
        /// 会话按工作目录归入项目：没绑文件夹就一个也归不进来，不能说"没有会话"。
        case needsFolder(Project)
        case none(inProject: Bool)
    }

    /// 列表空着时说什么；`project` 是此刻筛着的项目。
    func empty(filtering project: Project?, hasFolder: Bool) -> Empty {
        if searching { return .noMatch(query) }
        if let project, !hasFolder { return .needsFolder(project) }
        return .none(inProject: project != nil)
    }
}

extension PiSessionList {
    /// "现在"一段的行：两个以上需要 /reload 的会话合成一行。
    var nowRows: [PiNowRow<PiSessionListItem>] { PiNowRow.rows(now, state: \.state) }

    /// "历史"按结束时间分的段。
    var historyRuns: [PiHistorySection.Run<PiSessionListItem>] { PiHistorySection.split(ended, date: \.state.stateSince, now: .now) }
}

extension View {
    /// 读 Agent 页的列表（`filter` 是此刻的项目筛选）：随会话、投送请求、项目与目录绑定的变化重读，换搜索词或筛选时重新订阅；
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
