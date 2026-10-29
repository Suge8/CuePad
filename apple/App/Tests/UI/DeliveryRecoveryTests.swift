#if os(macOS)
import CueAgent
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

/// #43：回执丢失不是未执行，历史是投送与来源的正证据，回填不能重放绑定。
@MainActor
struct DeliveryRecoveryTests {
    private func session(_ app: TestApp, reply: String) async throws -> (PiSessionState, FakeExtension) {
        let id = UUID().uuidString.lowercased()
        let ext = try await app.host.connect(id, cwd: app.directory.path)
        ext.onCommand = { [weak ext] _, command in
            guard command["t"] as? String == "send" else { return ["ok": true] }
            switch reply {
            case "timeout": return nil
            case "disconnect": ext?.close(bye: "quit"); return nil
            case "failed": return ["ok": false, "error": "failed: 写入时连接断开"]
            default: return ["ok": true]
            }
        }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: id, state: .settled)
        return (try #require(try await app.services.store.allPiSessionStates().first { $0.sessionID == id }), ext)
    }

    private func say(_ text: String, to session: PiSessionState, app: TestApp) async throws -> DeliveryRequest {
        let box = app.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: text)
        await Workspace(services: app.services).speak(to: .session(session, mode: .send), from: box) { $0.stored }.value
        return try #require(try await app.services.store.deliveryRequests().first { $0.content == text })
    }

    private func history(_ messages: [PiMessage], session: String, app: TestApp) async throws {
        let file = app.directory.appending(path: "late.jsonl")
        let now = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(.now)
        var rows: [[String: Any]] = [["type": "session", "version": 3, "id": session, "timestamp": now, "cwd": app.directory.path]]
        for (index, message) in messages.enumerated() {
            rows.append([
                "type": "message", "id": "u\(index)", "parentId": index == 0 ? NSNull() : "u\(index - 1)" as Any, "timestamp": now,
                "message": ["role": "user", "content": message.text, "cuepadDelivery": message.deliveryID ?? ""],
            ])
        }
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(0x0A) }
        try data.write(to: file)
        let update = try PiHistory.index(file: file, agent: .pi, from: nil, files: app.services.store.files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(update)); $0.finish() }, agent: .pi)
    }

    @Test(arguments: ["timeout", "disconnect", "failed", "ack"])
    func 回执丢失或弱确认都不授权重发_晚到历史接替原气泡(reply: String) async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext) = try await session(app, reply: reply)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await say("从中断的地方继续", to: target, app: app)
        try await app.services.executor.start()
        let uncertain = try await store.outcome(of: request)
        #expect(uncertain.status == .known(.unconfirmed))
        #expect(uncertain.failure == nil)
        #expect(ext.messages.map(\.text) == ["从中断的地方继续"])
        #expect(PiChat.outgoing([uncertain], messages: []).map(\.id) == [request.id])

        let workspace = Workspace(services: app.services)
        await workspace.resend(.request(uncertain), restoringInto: app.services.settings.replyDraftBinding(for: target.id)).value
        #expect(workspace.notice?.isError == true)
        #expect(try await store.deliveryRequests(toSession: target.sessionID).map(\.id) == [request.id])

        await app.services.executor.beginStop()()
        try await app.services.executor.start()
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.unconfirmed))
        try await history(ext.messages, session: target.sessionID, app: app)
        let digest = try await SessionDigest.read(target.id, sessionID: target.sessionID, from: store)
        #expect(digest.messages.filter { $0.role == .known(.user) }.map(\.text) == ["从中断的地方继续"])
        #expect(PiChat.outgoing(digest.deliveries, messages: digest.messages).isEmpty)
        #expect(try await store.latest(of: request)?.status == .known(.succeeded))
        await app.services.executor.beginStop()()
    }

    @Test func 重开App与更新的旧pending同步都不能再派发已领取的话() async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext) = try await session(app, reply: "ack")
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await say("不要再上传一次", to: target, app: app)
        var old = try #require(try await store.syncRow(recordName: request.id.uuidString.lowercased()))
        // App 在交出后、写回前退出，磁盘上只剩领取事实。
        try RawDB(app.services.location.databaseURL).exec("UPDATE deliveryRequests SET status = 'executing', handledBy = '\(TestApp.hostID)'")
        try await app.services.executor.start()
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.unconfirmed))
        old.fields["modifiedAt"] = .int(Int64(Date.now.addingTimeInterval(60).timeIntervalSince1970 * 1000))
        #expect(try await store.applyRemote([.save(old, systemFields: Data())]).isEmpty)
        // 下一句正常处理完之后，旧意图也不得偷偷再次派发。
        let next = try await say("只检查结果", to: target, app: app)
        _ = try await store.outcome(of: next)
        #expect(ext.messages.map(\.text) == ["只检查结果"])
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.unconfirmed))
        await app.services.executor.beginStop()()
    }

    @Test func 先同步到真实消息也能确认原请求_不等弱ACK再次回来() async throws {
        let mac = TestApp(), phone = TestApp(host: "phone"), store = mac.services.store
        let (target, ext) = try await session(mac, reply: "ack")
        defer {
            ext.close(bye: "quit"); mac.pi.stop()
            mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork()
        }
        let request = try await say("只上传一次结果", to: target, app: phone)
        let pending = try #require(try await phone.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await store.applyRemote([.save(pending, systemFields: Data())]).isEmpty)
        try await mac.services.executor.start()
        _ = try await store.outcome(of: request)
        try await history(ext.messages, session: target.sessionID, app: mac)
        let message = try #require(try await store.piMessages(of: target.sessionID).first)
        let row = try #require(try await store.syncRow(recordName: message.id.uuidString.lowercased()))
        #expect(try await phone.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        let arrived = try #require(try await phone.services.store.latest(of: request))
        #expect(Said.request(arrived).trip(at: .always()) == .delivered)
        let digest = try await SessionDigest.read(target.id, sessionID: target.sessionID, from: phone.services.store)
        #expect(PiChat.outgoing(digest.deliveries, messages: digest.messages).isEmpty)
        #expect(digest.messages.map(\.text) == ["只上传一次结果"])
        await mac.services.executor.beginStop()()
    }

    @Test func 明确再说一次保留原来的未知_不伪装成安全重发() async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext) = try await session(app, reply: "ack")
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let first = try await say("继续检查", to: target, app: app)
        try await app.services.executor.start()
        let uncertain = try await store.outcome(of: first)
        let workspace = Workspace(services: app.services)
        await workspace.sayAgain(.request(uncertain), restoringInto: app.services.settings.replyDraftBinding(for: target.id)).value
        let second = try #require(try await store.deliveryRequests().first { $0.id != first.id })
        _ = try await store.outcome(of: second)
        #expect(try await store.deliveryRequests().count == 2)
        #expect(try await store.deliveryRequest(first.id)?.status == .known(.unconfirmed))
        #expect(ext.messages.map(\.text) == ["继续检查", "继续检查"])
        await app.services.executor.beginStop()()
    }

    @Test func 唤醒暂时连不上也不在一次领取里再开宿主() async throws {
        let app = TestApp(), store = app.services.store
        defer { app.pi.stop(); app.services.cancelBackgroundWork() }
        try await store.upsertPiSession(IndexedSession(
            id: "sleeping", path: app.directory.appending(path: "sleeping.jsonl").path, cwd: app.directory.path,
            title: "发布", lastActivityAt: .now), host: TestApp.hostID)
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "sleeping", state: .ended)
        let target = try #require(try await store.allPiSessionStates().first)
        app.host.resumeFailures = [PiHostError.notConnected]
        let request = try await say("检查一次发布结果", to: target, app: app)
        try await app.services.executor.start()
        let done = try await store.outcome(of: request)
        #expect(done.status == .known(.failed))
        #expect(app.host.extensions.isEmpty)
        #expect(try await store.deliveryRequests().map(\.id) == [request.id])
        await app.services.executor.beginStop()()
    }

    @Test(arguments: [AgentKind.claudeCode, .codex, .opencode, .grok, .dsh])
    func 其他接入仍保留各自的受理合同(agent: AgentKind) async throws {
        let app = TestApp(), store = app.services.store
        defer { app.pi.stop(); app.services.cancelBackgroundWork() }
        let runtime = PipedHostedAgent(bridge: app.pi, agent: agent)
        runtime.host("other", state: .settled)
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "other", state: .settled, agent: agent)
        let target = try #require(try await store.allPiSessionStates().first)
        let request = try await say("继续检查结果", to: target, app: app)
        try await app.services.executor.start()
        let done = try await store.outcome(of: request)
        #expect(done.status == .known(.succeeded))
        #expect(runtime.messages.map(\.text) == ["继续检查结果"])
        await app.services.executor.beginStop()()
    }

    @Test func Cue旧请求不能越过派发时新开始的人类轮() async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext) = try await session(app, reply: "ack")
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let task = try await store.createTask("修复发布")
        try await store.bindSession(target.sessionID, to: task.id)
        let host = TestApp.hostID
        try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let cue = CueTools(store: store, wait: 0)
        _ = await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "先检查一次"])
        let first = try #require(try await store.deliveryRequests().first)
        try await app.services.executor.start()
        _ = try await store.outcome(of: first)
        await app.services.executor.beginStop()()
        try await history(ext.messages, session: target.sessionID, app: app)
        ext.setState(["kind": "thinking"])
        try await eventually("宿主开始 Cue 的一轮") { app.pi.session(id: ext.id)?.turnStartedAt != nil }
        let began = try #require(app.pi.session(id: ext.id)?.turnStartedAt)
        let recorder = try await app.runtimeRecorder(on: host)
        try await recorder.update(sessionID: target.sessionID, state: .thinking, turnStartedAt: began)
        let queued = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "接着检查上传"]))
        #expect(!queued.isError)
        let second = try #require(try await store.deliveryRequests().first { $0.id != first.id })

        // 库还是 Cue 的旧报告，宿主已进入另一轮：不能拿旧报告授权打断。
        let newTurn = Int64(began.addingTimeInterval(1).timeIntervalSince1970 * 1000)
        ext.sendRaw("{\"t\":\"state\",\"state\":{\"kind\":\"thinking\",\"since\":\(newTurn),\"turnSince\":\(newTurn)}}")
        try await eventually("桥看到后来的一轮") { app.pi.session(id: ext.id)?.turnStartedAt != began }
        try await app.services.executor.start()
        let rejected = try await store.outcome(of: second)
        #expect(rejected.status == .known(.failed))
        #expect(ext.messages.map(\.text) == ["先检查一次"])
        #expect(app.pi.session(id: ext.id)?.state == .thinking)
        await app.services.executor.beginStop()()
    }

    @Test func Cue超时后的历史补齐来源_清理请求后仍保留_不抢后来手动绑定() async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext) = try await session(app, reply: "timeout")
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let task = try await store.createTask("修复发布")
        try await store.bindSession(target.sessionID, to: task.id)
        let host = TestApp.hostID
        try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let result = try #require(await CueTools(store: store, wait: 0).call("task", [
            "action": "say", "task": task.id.uuidString, "text": "接着检查发布结果",
        ]))
        #expect(!result.isError)
        let request = try #require(try await store.deliveryRequests().first)
        try await app.services.executor.start()
        _ = try await store.outcome(of: request)
        let workspace = Workspace(services: app.services), taskID = task.id
        workspace.perform { try await $0.bindSession("later-session", to: taskID) }
        try await eventually("手动改绑生效") { try await store.leafSession(taskID) == "later-session" }
        try await history(ext.messages, session: target.sessionID, app: app)
        #expect(try await store.leafSession(task.id) == "later-session")
        let digest = try await SessionDigest.read(target.id, sessionID: target.sessionID, from: store)
        #expect(digest.cueSent == [request.id])
        try await store.deleteDelivery(request.id)
        try await history(ext.messages, session: target.sessionID, app: app)
        let reloaded = try await SessionDigest.read(target.id, sessionID: target.sessionID, from: store)
        #expect(reloaded.cueSent == [request.id])
        #expect(try await store.leafSession(task.id) == "later-session")
        #expect(try RawDB(app.services.location.databaseURL).count("sendRecords") == 1)
        await app.services.executor.beginStop()()
    }
}
#endif
