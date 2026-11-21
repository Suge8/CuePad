import CueStore

extension Workspace {
    func stop(_ session: SessionState) async {
        do {
            let request = try await services.stop(session)
            if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
        } catch { fail(error) }
    }

    func end(_ session: SessionState) async {
        do { _ = try await services.end(session) } catch { fail(error) }
    }

    func sleep(_ session: SessionState) {
        if pulse(of: SessionListItem(state: session)).shown?.agentBusy == true { sessionAsk = .end(session) } else { Task { await end(session) } }
    }

    func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { fail(error) }
        }
    }

    func perform(_ work: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store
        attempt { try await work(store) }
    }
}
