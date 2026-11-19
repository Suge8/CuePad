import CueStore
import SwiftUI

#if os(iOS)

@Observable
final class AgentListModel {
    var list: SessionListData?
    var query = "" { didSet { resetPaging() } }
    private(set) var limit = SessionListData.pageSize

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var hasMore: Bool { list?.hasMore ?? false }

    func resetPaging() { limit = SessionListData.pageSize }

    func loadMore() {
        if let list { limit = list.loaded + SessionListData.pageSize }
    }

    static var noneTitle: String { String(localized: "还没有 Agent 会话") }
}

#endif

extension SessionListData {
    /// 正在唤醒的读的时候就排掉了（`SessionListData.earlier`）。
    var historyRuns: [TimeSection.Run<SessionListItem>] {
        TimeSection.split(ended, date: \.state.stateSince, now: .now)
    }
}

#if os(iOS)
extension View {
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
                services.store, id: SessionListData.Key(filter: .init(text: model.query, project: nil), limit: model.limit, moment: services.speech),
                into: $model.list, onError: workspace.fail
            ) { [query = model.query, limit = model.limit, moment = services.speech] store in
                try SessionListData.read(text: query, historyLimit: limit, at: moment, from: store)
            }
    }
}
#endif
