#if os(macOS)
import CueBridge
#endif
import CueStore
import Foundation

extension AppServices {
    /// 这台就是会话所在的 Mac：点开一步当场回会话文件取，在跑的一轮也取得到。
    func holdsSteps(of session: SessionState) -> Bool {
        #if os(macOS)
        session.hostID == speech.localHost || DebugHooks.preset.demoMac
        #else
        false
        #endif
    }

    #if os(macOS)
    /// 会话所在的 Mac 办别的设备的请求（`DeliveryMode.step`）：取了写在那一步上。会话文件没了、读不了按失败写回原因，不写一份空的。
    nonisolated static func fillStep(_ content: String, in store: CueStore) async throws {
        guard let step = try await store.stepCalls(content) else { throw SendError.sessionFileMissing }
        try await store.fillStep(content, with: try await stepDetail(step.calls, of: step.session, in: store))
    }

    nonisolated static func stepDetail(_ calls: [String], of sessionID: String, in store: CueStore) async throws -> ToolCallDetail {
        guard let indexed = try await store.indexedSession(sessionID) else { throw SendError.sessionFileMissing }
        do { return try await ToolCallDetail.read(file: URL(filePath: indexed.path), calls: calls) } catch { throw SendError.sessionFileMissing }
    }
    #endif

    /// 别的设备上：请会话所在的 Mac 取了写在那一步上（`ChatMessage.Tools.Item.detail`），等它办完；那台没开、没取到、一分钟没回音都抛出原因。
    func fetchStep(_ item: Int, of message: UUID, in session: SessionState) async throws {
        let request = try await request(on: session.hostID) { try await store.requestStep(item, of: message, in: session) }
        let deadline = timing.now().addingTimeInterval(Speech.receiptLimit)
        let result = try await withThrowingTaskGroup(of: DeliveryRequest.self) { [store, timing] group in
            group.addTask { try await store.outcome(of: request) }
            group.addTask {
                try await timing.sleepUntil(deadline)
                throw SendError.noReply
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if let failure = result.failure { throw SendError.notDelivered(failure) }
    }
}
