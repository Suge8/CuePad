import CueStore
import CueText
import Foundation

extension Workspace {
    func adopt(_ session: SessionState) async throws -> UUID {
        try await services.store.adoptSession(session.sessionID)
    }

    func finish(_ agent: SessionListItem) async throws {
        let session = agent.state
        if let task = try await openTask(of: session) { return try await confirmComplete(task.id) }
        try await confirmComplete(nil, subtasks: nil, busy: pulse(of: agent).shown?.agentBusy == true ? session : nil) {
            try await $0.complete(try await $0.adopt(session))
        }
    }

    private func openTask(of session: SessionState) async throws -> Card? {
        let owner = try await services.store.sessionOwners([session.sessionID])[session.sessionID]
        return owner?.leaf.completedAt == nil ? owner?.task : nil
    }

    func pin(_ session: SessionState) async throws {
        let task = try await adopt(session)
        try await services.store.updateCard(task) { $0.isPinned = true }
    }

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
