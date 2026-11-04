#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

/// #58：从回复框发斜杠命令，送达各家一条规则。模板与技能是你说的话：带着请求 id 交给 Agent，对话里挂着气泡，
/// 落成的那条消息出现才算送达、气泡由它换下；Agent 拒收写原因。扩展命令是命令：Agent 执行了它就已送达，不挂气泡、进度收起。
/// Agent 这一端（Pi 展开模板、执行扩展命令后确认）的真实行为在 CuePiTests 的 `RealSlashTests`。
@MainActor
struct SlashDeliveryTests {
    static let commands = [
        PiSlashCommand(name: "greet", summary: "Greet someone", source: .known(.prompt)),
        PiSlashCommand(name: "skill:careful", summary: "Work carefully", source: .known(.skill)),
        PiSlashCommand(name: "shout", summary: "Shout the arguments", source: .known(.extension)),
    ]

    enum Agent: String, CaseIterable { case delivers, refuses }

    @Test(arguments: ["/greet world", "/skill:careful 小心点", "/shout hi"], Agent.allCases)
    func 回复框发模板技能与扩展命令_按真实结果显示已送达或失败原因(line: String, agent: Agent) async throws {
        let app = TestApp(), store = app.services.store
        let id = UUID().uuidString.lowercased()
        let ext = try await app.host.connect(id, cwd: app.directory.path)
        if agent == .refuses {
            ext.onCommand = { _, command in ["send", "command"].contains(command["t"] as? String) ? ["ok": false, "error": "no_auth"] : ["ok": true] }
        }
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        try await app.runtimeRecorder(on: TestApp.hostID).update(sessionID: id, state: .settled)
        let session = try #require(try await store.allPiSessionStates().first { $0.sessionID == id })

        let box = app.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: line)
        await Workspace(services: app.services).reply(to: session, commands: Self.commands, from: box, accepting: .reply).value
        let request = try #require(try await store.deliveryRequests(toSession: id).last)
        let said = !line.hasPrefix("/shout")
        #expect(request.mode == .known(said ? .send : .command))
        #expect(PiChat.outgoing([request], messages: []).map(\.id) == (said ? [request.id] : []), "说的话挂气泡，命令不挂")

        try await app.services.executor.start()
        let done = try await store.outcome(of: request)
        let messages = try await store.piMessages(of: id)
        let delivered = Speech.trip(done, at: app.services.speech)
        switch agent {
        case .delivers:
            #expect(delivered == .delivered)
            #expect(PiChat.outgoing([done], messages: messages).isEmpty, "气泡由对话换下")
            #expect(messages.compactMap(\.deliveryID) == (said ? [request.id] : []))
            #expect(MacDelivery.commandProgress([done], messages: messages, at: app.services.speech) == nil)
        case .refuses:
            #expect(delivered.failure != nil && delivered.unconfirmedReason == nil, "明确拒收是没送到，写原因")
            if said { #expect(PiChat.outgoing([done], messages: messages).map(\.id) == [request.id], "没送到的话留在对话里等重发") }
            else { #expect(MacDelivery.commandProgress([done], messages: messages, at: app.services.speech)?.failed == true) }
        }
        #expect(ext.messages.map(\.deliveryID) == (said ? [request.id.uuidString] : []), "说的话带着请求 id 交出")
        #expect(ext.received.contains("command") == !said)
        await app.services.executor.beginStop()()
    }
}
#endif
