import CueStore
import CueText
import Foundation

/// 只在看板上建任务，别处给没绑任务的会话改名仍只是让 Agent 改。
/// 名字只有一个事实源——任务标题：绑着任务的会话改名改的是它绑着的叶子的标题，再对做得到的 Agent（`MacDelivery.canRename`）发改名；
/// 标题为空的任务显示会话名、随会话改名变（`Card.title(session:)`）。
extension Workspace {
    func adopt(_ session: SessionState) async throws -> UUID {
        try await services.store.adoptSession(session.sessionID)
    }

    /// 会话在做或在等你时先问一句（`SessionAsk.complete`），答应了才建任务、完成；取消什么都不留。
    func finish(_ agent: SessionListItem) async throws {
        if pulse(of: agent).shown?.agentBusy == true { return sessionAsk = .complete(agent.state) }
        try await complete(agent.state)
    }

    func confirmFinish(_ session: SessionState) async throws { try await complete(session) }

    /// 只经 `finish` 与 `confirmFinish`：界面直接调它就跳过了在做时的那一问。
    private func complete(_ session: SessionState) async throws {
        try await complete(try await adopt(session))
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

    /// 标题为空（跟着会话名）、已经同名、做不到改名的（终端里的 Grok 这类，只读跟读）不发。
    func pushName(of leaf: UUID) async throws {
        let store = services.store
        guard let card = try await store.card(leaf), card.isTask, !card.heading.isEmpty, let sessionID = card.piSessionID,
            let session = try await store.piSessions(sessionIDs: [sessionID])[sessionID]
        else { return }
        let name = CueName.clipped(card.heading)
        guard MacDelivery.canRename(session.state), name != session.shownTitle(at: services.speech) else { return }
        _ = try await services.rename(session.state, to: name)
    }
}
