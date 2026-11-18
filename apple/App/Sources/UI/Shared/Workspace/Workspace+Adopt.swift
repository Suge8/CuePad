import CueStore
import CueText
import Foundation

/// 没归着任务的活会话第一次被当任务用（完成、置顶、改名，哪一处的菜单都一样）时当场建任务；已结束的不建，改名只让 Agent 改。
/// 名字只有一个事实源——任务标题：绑着任务的会话改名改的是它绑着的叶子的标题，再对 Agent 发改名；
/// 标题为空的任务显示会话名、随会话改名变（`Card.title(session:)`）。
extension Workspace {
    func adopt(_ session: SessionState) async throws -> UUID {
        try await services.store.adoptSession(session.sessionID)
    }

    /// 完成一个会话。归着任务的就是完成那件任务；没归着的当场给它建一件再完成。会话休不休眠都照完成的那一条规则（`complete`）。
    /// 会话在做或在等你时先问一句（`confirmComplete`），答应了才动；取消什么都不留。
    /// 归没归着只问库里此刻的（`openTask`），不信界面手里的那份：它可能只归着做完的旧任务，问着的时候也可能被别的任务接走（`adopt` 返回的就是那一件）。
    func finish(_ agent: SessionListItem) async throws {
        let session = agent.state
        if let task = try await openTask(of: session) { return try await confirmComplete(task) }
        try await confirmComplete(nil, subtasks: nil, busy: pulse(of: agent).shown?.agentBusy == true ? session : nil) {
            try await $0.complete(try await $0.adopt(session))
        }
    }

    /// 它归着的那件没做完的事的顶层任务。
    private func openTask(of session: SessionState) async throws -> Card? {
        let owner = try await services.store.sessionOwners([session.sessionID])[session.sessionID]
        return owner?.leaf.completedAt == nil ? owner?.task : nil
    }

    func pin(_ session: SessionState) async throws {
        let task = try await adopt(session)
        try await services.store.updateCard(task) { $0.isPinned = true }
    }

    /// 没绑着没做完的任务的活会话（`adopts`）先建任务——只绑着做完的旧任务的也建，不改旧任务的名字；一件都没绑的只让 Agent 改名。
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
