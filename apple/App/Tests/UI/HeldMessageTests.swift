#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

@MainActor
struct HeldMessageTests {
    /// 送去会被终端扣下等批准的话（跳过权限确认的 Claude Code、CuePad 还没拿到它的收件凭证，见 `ClaudeBypass`），会话不发、拒收：
    /// 投送报没送到并写明原因与怎么办，不按未确认处理，话留在对话里等重发。
    @Test func 会被终端扣下的话_报没有发出并说明怎么办() async throws {
        let app = TestApp(), store = app.services.store
        let id = UUID().uuidString.lowercased()
        let ext = try await app.host.connect(id, cwd: app.directory.path)
        ext.onCommand = { _, command in command["t"] as? String == "send" ? ["ok": false, "error": "unattested"] : ["ok": true] }
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        try await app.runtimeRecorder(on: TestApp.hostID).update(sessionID: id, state: .settled)
        let session = try #require(try await store.allPiSessionStates().first { $0.sessionID == id })

        let box = app.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: "看一下构建")
        await Workspace(services: app.services).reply(to: session, commands: [], from: box, accepting: .reply).value
        let request = try #require(try await store.deliveryRequests(toSession: id).last)
        try await app.services.executor.start()
        let done = try await store.outcome(of: request)

        #expect(done.status == .known(.failed))
        #expect(done.reason == ShownText(PiBridgeError.rejected("unattested")))
        #expect(PiChat.outgoing([done], messages: try await store.piMessages(of: id)).map(\.id) == [request.id], "没送到的话留在对话里等重发")
        await app.services.executor.beginStop()()
    }
}
#endif
