#if os(macOS)
import CueStore
import Foundation

public struct SessionMirror {
    private let recorder: StateRecorder
    private var live: [Session.ID: Session] = [:]
    private var store: CueStore { recorder.store }

    public init(recorder: StateRecorder) {
        self.recorder = recorder
    }

    public mutating func apply(_ change: SessionChange) async throws {
        switch change {
        case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session):
            let previous = live.updateValue(session, forKey: session.id)
            if owner(of: session.sessionID)?.id == session.id { try await record(session) }
            if previous?.model != session.model || previous?.availableModels != session.availableModels || previous?.proofs != session.proofs {
                try await store.retainQuotaSources(on: recorder.hostID, live: live.values.map {
                    QuotaWitness(sessionID: $0.sessionID, models: $0.availableModels + [$0.model].compactMap { $0 }, proofs: $0.proofs)
                })
            }
        case .ended(let session, let reason):
            live[session.id] = nil
            if let other = owner(of: session.sessionID) { return try await record(other) }
            if reason != .reload { try await recorder.exited(sessionID: session.sessionID, spoke: session.spoke) }
        case .quota(let report):
            try await store.recordQuota(report, host: recorder.hostID, proofs: live.values.flatMap(\.proofs))
        }
    }

    private func owner(of sessionID: String) -> Session? {
        live.values.first { $0.sessionID == sessionID }
    }

    private func record(_ session: Session) async throws {
        guard !session.upgrading else { return }
        let title = session.name != nil || session.firstMessage != nil
            ? session.displayName : try await store.indexedSession(session.sessionID)?.title ?? session.displayName
        let snapshot = session.snapshot(title: title, projectID: try await store.project(containing: session.cwd)?.id)
        _ = try await recorder.update(snapshot)
    }
}
#endif
