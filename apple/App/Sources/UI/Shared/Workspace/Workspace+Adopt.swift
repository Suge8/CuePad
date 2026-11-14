import CueStore
import CueText
import Foundation

/// 只在看板上建任务，别处给没绑任务的会话改名仍只是让 Agent 改。
/// 名字只有一个事实源——任务标题：绑着任务的会话改名改的是它绑着的叶子的标题，再对 Agent 发改名；
/// 标题为空的任务显示会话名、随会话改名变（`Card.title(session:)`）。
extension Workspace {
    func adopt(_ session: SessionState) async throws -> UUID {
        try await services.store.adoptSession(session.sessionID)
    }

    /// 会话在做或在等你时先问一句（`confirmComplete`），答应了才建任务、完成；取消什么都不留。
    func finish(_ agent: SessionListItem) async throws {
        let session = agent.state
        try await confirmComplete(nil, subtasks: nil, busy: pulse(of: agent).shown?.agentBusy == true ? session : nil) {
            try await $0.complete(try await $0.adopt(session))
        }
    }

    func pin(_ session: SessionState) async throws {
        let task = try await adopt(session)
        try await services.store.updateCard(task) { $0.isPinned = true }
    }

    /// 没绑着没做完的任务的，在看板上（`adopts`）先建任务——只绑着做完的旧任务的也建，不改旧任务的名字；一件都没绑的只让 Agent 改名。
    func rename(_ session: SessionState, to name: String, adopts: Bool) async throws {
        guard let name = SessionRename.clean(name) else { throw CueStoreError.blankDeliveryContent }
        let store = services.store
        let owner = try await store.sessionOwners([session.sessionID])[session.sessionID]?.leaf
        var leaf = owner?.completedAt == nil ? owner?.id : nil
        if leaf == nil { leaf = adopts ? try await adopt(session) : owner?.id }
        guard let leaf else {
            _ = try await services.rename(session, to: name)
            return
        }
        try await store.updateCard(leaf) { $0.body = CueLines.joined(title: name, rest: $0.rest) }
        try await pushName(of: leaf)
    }

    /// 标题为空（跟着会话名）、已经同名的不发。
    func pushName(of leaf: UUID) async throws {
        let store = services.store
        guard let card = try await store.card(leaf), card.isTask, !card.heading.isEmpty, let sessionID = card.piSessionID,
            let session = try await store.sessionItems(sessionIDs: [sessionID])[sessionID]
        else { return }
        let name = CueName.clipped(card.heading)
        guard name != session.shownTitle(at: services.speech) else { return }
        _ = try await services.rename(session.state, to: name)
    }
}
