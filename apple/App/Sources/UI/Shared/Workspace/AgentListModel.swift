import CueStore
import SwiftUI

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

    func loadMore() {
        if let list { limit = list.loaded + PiSessionList.pageSize }
    }

    static var noneTitle: String { String(localized: "还没有 Agent 会话") }
}

extension PiSessionList {
    /// 正在唤醒的读的时候就排掉了（`PiSessionList.earlier`）。
    var historyRuns: [TimeSection.Run<PiSessionListItem>] {
        TimeSection.split(ended, date: \.state.stateSince, now: .now)
    }
}

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
                services.store, id: PiSessionList.Key(filter: .init(text: model.query, project: nil), limit: model.limit, moment: services.speech),
                into: $model.list, onError: workspace.fail
            ) { [query = model.query, endedOnly = model.endedOnly, limit = model.limit, moment = services.speech] store in
                try PiSessionList.read(text: query, endedOnly: endedOnly, historyLimit: limit, at: moment, from: store)
            }
    }
}
