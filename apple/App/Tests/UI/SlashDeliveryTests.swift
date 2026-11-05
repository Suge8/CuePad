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

    /// 带着卡片（与批注）发：Agent 只认开头的 `/名字`，交出去的那句以你打的命令开头、名字后一个空格，卡片与批注接在后面当参数。
    @Test(arguments: ["/greet", "/skill:careful", "/shout"])
    func 带卡片与批注发命令_交出的仍以命令开头(line: String) async throws {
        let app = TestApp(), store = app.services.store
        let id = UUID().uuidString.lowercased()
        let ext = try await app.host.connect(id, cwd: app.directory.path)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        try await app.runtimeRecorder(on: TestApp.hostID).update(sessionID: id, state: .settled)
        let session = try #require(try await store.allPiSessionStates().first { $0.sessionID == id })

        let box = app.services.settings.replyDraftBinding(for: session.id)
        let note = ReplyNote(entry: UUID(), run: 0, location: 0, quote: "登录按钮", note: "太小")
        box.wrappedValue = ComposerDraft(text: line, attachments: [Outbox(content: "卡片：登录页改版")], notes: [note])
        await Workspace(services: app.services).reply(to: session, commands: Self.commands, from: box, accepting: .reply).value
        try await app.services.executor.start()
        let request = try #require(try await store.deliveryRequests(toSession: id).last)
        _ = try await store.outcome(of: request)
        let sent = line == "/shout"
            ? try #require(ext.commands.map(\.json).first { $0["t"] as? String == "command" }?["text"] as? String)
            : try #require(ext.messages.first?.text)
        #expect(sent.hasPrefix(line + " 卡片：登录页改版"), "\(sent)")
        await app.services.executor.beginStop()()
    }

    /// 托管的 Claude Code 报的命令都是它自己执行的（自定义命令与技能也在其中）：它真做了才是已送达；没登录、模型不可用、额度用完时
    /// 它取消这一条，回复框上方写它的原话，不报已送达，也不只写"尚未确认"。Claude Code 这一端的真实行为在 CuePiTests 的 `RealClaudeHostTests`。
    @Test(arguments: [nil, "Not logged in · Please run /login"])
    func 托管ClaudeCode执行了命令才算送达_拒收写它的原话(refusal: String?) async throws {
        let app = TestApp(), store = app.services.store
        defer { app.pi.stop(); app.services.cancelBackgroundWork() }
        app.claude.refusal = refusal
        app.claude.host("claude", state: .settled)
        try await app.runtimeRecorder(on: TestApp.hostID).update(sessionID: "claude", state: .settled, agent: .claudeCode)
        let session = try #require(try await store.allPiSessionStates().first { $0.sessionID == "claude" })
        let review = PiSlashCommand(name: "review", summary: "Review the changes", source: .known(.builtin))

        let box = app.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: "/review 登录页")
        await Workspace(services: app.services).reply(to: session, commands: [review], from: box, accepting: .reply).value
        let request = try #require(try await store.deliveryRequests(toSession: "claude").last)
        #expect(request.mode == .known(.command))
        try await app.services.executor.start()
        let done = try await store.outcome(of: request)
        let progress = MacDelivery.commandProgress([done], messages: [], at: app.services.speech)
        if let refusal {
            #expect(progress == .failed(command: "/review", failure: .reported(refusal)))
            #expect(app.claude.commands.isEmpty)
        } else {
            #expect(Speech.trip(done, at: app.services.speech) == .delivered && progress == nil)
            #expect(app.claude.commands == ["/review 登录页"])
        }
        await app.services.executor.beginStop()()
    }
}
#endif
