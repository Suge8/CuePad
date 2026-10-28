#if os(macOS)
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 出错后点"重试"（`Workspace.retry`）：投送请求交给会话所在的 Mac，会话行当场显示话在路上；Mac 让会话的扩展重跑出错的那一轮，
/// 对话里不多一句话、不写发送记录（只会多出新的回答）；连点只发一次。
struct RetryTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 重试_当场在路上_Mac让扩展重跑_对话里不多一句话() async throws {
        let ext = try await app.host.connect("atlas", cwd: "/work/atlas")
        ext.setState(["kind": "error", "error": "fetch failed"])
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(
            sessionID: "atlas", state: .error, detail: "fetch failed", failure: .network, title: "atlas", directory: "/work/atlas")
        let said = PiChatMessage(sessionID: "atlas", entryID: "u1", seq: 1, role: .user, text: "跑一遍", at: .now)
        try await store.writePiTranscript(PiTranscript(sessionID: "atlas", messages: [said], recap: PiRecap(lastPrompt: "跑一遍")))
        let session = try #require(try await store.allPiSessionStates().first)
        #expect(session.canRetry)

        let workspace = Workspace(services: app.services)
        workspace.retry(session)
        workspace.retry(session)
        let request = try #require(try await eventually(store, { try $0.deliveryRequests(toSession: "atlas").last }) { $0 != nil })
        #expect(request.mode == .known(.retry) && request.hostID == TestApp.hostID)
        let item = try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
        #expect(workspace.shown(item).status == .delivery(.inTransit(.sending)))

        try await app.services.executor.start()
        defer { app.services.cancelBackgroundWork() }
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(ext.received == ["retry"])
        #expect(try await store.deliveryRequests(toSession: "atlas").count == 1)
        #expect(try await store.piMessages(of: "atlas").map(\.text) == ["跑一遍"])
        #expect(try RawDB(app.services.location.databaseURL).count("sendRecords") == 0)
    }
}
#endif
