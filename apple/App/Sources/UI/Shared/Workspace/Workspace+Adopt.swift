import CueStore
import CueText
import Foundation

/// 看板上的任务与不归没做完的事的活会话支持同一组操作：拖到已完成、完成、置顶、改名。会话第一次被这样用时当场建任务绑上（`CueStore.adoptSession`），
/// 再照任务的走；只在看板上建，别处（"更早"、搜索、会话页）给没绑任务的会话改名仍只是让 Agent 改。
/// 名字只有一个事实源——任务标题：绑着任务的会话改名改的是它绑着的叶子的标题，再对做得到的 Agent（`MacDelivery.canRename`）发改名；
/// 标题为空的任务显示会话名、随会话改名变（`Card.title(session:)`）。
extension Workspace {
    /// 当场给看板上的这个会话建任务（已有没做完的任务绑着它就是那件），返回顶层任务。
    func adopt(_ session: PiSessionState) async throws -> UUID {
        try await services.store.adoptSession(session.sessionID)
    }

    /// 看板上的会话拖到已完成、点完成：建任务再完成它（同点完成圈，`toggle`；托管的会话照做完的规则结束，终端里的随之收起）。
    func complete(_ session: PiSessionState) async throws {
        try await toggle(try await adopt(session))
    }

    /// 看板上的会话置顶：置的是给它建的那件任务。
    func pin(_ session: PiSessionState) async throws {
        let task = try await adopt(session)
        try await services.store.updateCard(task) { $0.isPinned = true }
    }

    /// 重命名会话（会话菜单的"重命名"，`SessionAsk.rename`）：绑着没做完的任务的改那个叶子（最近开始的）的标题；没有的在看板上（`adopts`）先建任务——
    /// 只绑着做完的旧任务的也建，不改旧任务的名字；别处的改它绑着的最近那件，一件都没绑的只让 Agent 改名。挑哪件同会话行读名字（`CueStore.sessionTasks`）。
    func rename(_ session: PiSessionState, to name: String, adopts: Bool) async throws {
        guard let name = PiRename.clean(name) else { throw CueStoreError.blankDeliveryContent }
        let store = services.store
        let bound = try await store.tasks(boundTo: session.sessionID).map(\.task).filter { $0.piSessionID == session.sessionID }
        var leaf = bound.last { $0.completedAt == nil }?.id
        if leaf == nil { leaf = adopts ? try await adopt(session) : bound.last?.id }
        guard let leaf else {
            _ = try await services.rename(session, to: name)
            return
        }
        try await store.updateCard(leaf) { $0.body = CueLines.joined(title: name, rest: $0.rest) }
        try await pushName(of: leaf)
    }

    /// 叶子的标题改过了（重命名、离开任务正文的编辑）：它绑着的会话做得到改名时，让 Agent 也叫这个名字（截断规则同开会话起名，`CueName.clipped`）。
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
