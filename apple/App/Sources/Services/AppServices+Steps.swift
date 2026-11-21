#if os(macOS)
import CueBridge
#endif
import CueStore
import Foundation

extension AppServices {
    func holdsSteps(of session: SessionState) -> Bool {
        #if os(macOS)
        session.hostID == speech.localHost || DebugHooks.preset.demoMac
        #else
        false
        #endif
    }

    #if os(macOS)
    static func fillStep(_ content: String, in store: CueStore, runtimes: [AgentKind: any AgentRuntime]) async throws {
        guard let step = try await store.stepCalls(content) else { throw SendError.sessionFileMissing }
        try await store.fillStep(content, calls: step.calls, with: try await stepDetail(step.calls, of: step.session, in: store, runtimes: runtimes))
    }

    static func stepDetail(
        _ calls: [String], of sessionID: String, in store: CueStore, runtimes: [AgentKind: any AgentRuntime]
    ) async throws -> ToolCallDetail {
        guard let indexed = try await store.indexedSession(sessionID) else { throw SendError.sessionFileMissing }
        do {
            guard let runtime = runtimes[indexed.agent] else { return try await ToolCallDetail.read(file: URL(filePath: indexed.path), calls: calls) }
            return try await runtime.stepDetail(calls, of: indexed)
        } catch {
            throw SendError.sessionFileMissing
        }
    }
    #endif

    func fetchStep(_ item: Int, of message: UUID, in session: SessionState) async throws {
        let result = try await awaitOutcome(onTimeout: SendError.noReply) {
            try await request(on: session.hostID) { try await store.requestStep(item, of: message, in: session) }
        }
        if let failure = result.failure { throw SendError.notDelivered(failure) }
    }
}
