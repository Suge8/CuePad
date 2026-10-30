#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// #43 复审：从回复框提交命令，明确拒绝与结果未确认分别展示；后来有对话或新请求时收起。
@MainActor
struct CommandProgressTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func command() async throws -> DeliveryRequest {
        let workspace = Workspace(services: app.services)
        let box = app.services.settings.replyDraftBinding(for: PiSessionState.recordID(sessionID: "atlas"))
        box.wrappedValue = ComposerDraft(text: "/compact")
        await workspace.speak(to: .session(
            SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), host: TestApp.hostID, mode: .command, card: nil), from: box) { $0.stored }.value
        return try #require(try await store.deliveryRequests(toSession: "atlas").last)
    }

    private func progress() async throws -> MacDelivery.CommandProgress? {
        MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas"), messages: try await store.piMessages(of: "atlas"), at: app.services.speech)
    }

    @Test(arguments: ["timeout", "disconnect", "failed"], [true, false])
    func 命令结果未知不再冒充正在执行_后来对话或新请求会收起提示(fault: String, laterMessage: Bool) async throws {
        let ext = try await app.host.connect("atlas", cwd: app.directory.path)
        ext.onCommand = { [weak ext] _, command in
            guard command["t"] as? String == "command" else { return ["ok": true] }
            switch fault {
            case "timeout": return nil
            case "disconnect": ext?.close(bye: "quit"); return nil
            default: return ["ok": false, "error": "failed: Nothing to compact (session too small)"]
            }
        }
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await command()
        #expect(try await progress() == .running("/compact"))
        try await app.services.executor.start()
        let result = try await store.outcome(of: request)
        #expect(result.status == .known(.unconfirmed))
        #expect(try await progress() != .running("/compact"))
        #expect(try await progress()?.text.contains("尚未确认") == true)
        #expect(try await progress()?.failed == false)
        if laterMessage {
            let later = try #require(result.completedAt).addingTimeInterval(0.001)
            try await store.writePiTranscript(PiTranscript(sessionID: "atlas", messages: [
                PiChatMessage(sessionID: "atlas", entryID: "later", seq: 1, role: .user, text: "终端里说的下一句", at: later),
            ], recap: PiRecap()))
        } else {
            await Workspace(services: app.services).speak("下一句", to: .session(
                SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), host: TestApp.hostID, mode: .send, card: nil)).value
        }
        #expect(try await progress() == nil)
        await app.services.executor.beginStop()()
    }

    @Test func 明确拒绝的命令写失败原因_新请求替换旧提示() async throws {
        let ext = try await app.host.connect("atlas", cwd: app.directory.path)
        ext.onCommand = { _, command in
            command["t"] as? String == "command" ? ["ok": false, "error": "unknown_command"] : ["ok": true]
        }
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        try await app.services.executor.start()
        let request = try await command()
        #expect(try await store.outcome(of: request).status == .known(.failed))
        #expect(try await progress()?.failed == true)
        await Workspace(services: app.services).speak("下一句", to: .session(
            SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), host: TestApp.hostID, mode: .send, card: nil)).value
        #expect(try await progress() == nil)
        await app.services.executor.beginStop()()
    }
}
#endif
