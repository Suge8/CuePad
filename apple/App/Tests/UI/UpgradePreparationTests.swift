#if os(macOS)
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// #43 真机追加：升级是尚未派发的准备，不是投送失败，也不授权重做已开始的操作。
@MainActor
struct UpgradePreparationTests {
    func oldSession(_ app: TestApp) async throws -> (PiSessionState, FakeExtension) {
        let ext = try await app.host.connect("upgrade-target", cwd: app.directory.path, extensionVersion: 0)
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled)
        return (try #require(try await app.services.store.allPiSessionStates().first { $0.sessionID == ext.sessionID }), ext)
    }

    func prepared(_ request: DeliveryRequest, in app: TestApp) async throws -> DeliveryRequest {
        try await eventually("原请求等待准备或已有执行结果") {
            guard let current = try await app.services.store.deliveryRequest(request.id) else { return false }
            return !current.isOpen || current.status == .known(.preparing) && current.reason != nil
        }
        return try #require(try await app.services.store.deliveryRequest(request.id))
    }

    func sendOther(in app: TestApp) async throws {
        let other = try await app.host.connect(UUID().uuidString.lowercased(), cwd: app.directory.path)
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: other.sessionID, state: .settled)
        let target = try #require(try await app.services.store.allPiSessionStates().first { $0.sessionID == other.sessionID })
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "其他会话先完成"), to: target, mode: .send)
        #expect(try await app.services.store.outcome(of: request).status == .known(.succeeded))
        #expect(other.messages.map(\.text) == ["其他会话先完成"])
    }

    @Test func 升级准备保留原请求与原因_不挡其他会话_重连后只派发一次() async throws {
        let app = TestApp(), store = app.services.store
        let (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "升级好后处理这一句"), to: target, mode: .send)
        try await app.services.executor.start()
        let waiting = try await prepared(request, in: app)
        #expect(waiting.status == .known(.preparing) && waiting.handledBy == nil)
        #expect(waiting.deadlineAt != nil && waiting.reason != nil)
        #expect(waiting.failure == nil && !Speech.trip(waiting, at: app.services.speech).inTransit)
        #expect(old.messages.isEmpty)
        guard waiting.status == .known(.preparing) else { await app.services.executor.beginStop()(); return }
        try await sendOther(in: app)
        old.close(bye: "reload")
        let ready = try await app.host.connect(target.sessionID, cwd: app.directory.path)
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(ready.messages.map(\.deliveryID) == [request.id.uuidString])
        #expect(app.host.calls.isEmpty)
        let source = try await SessionDigest.read(target.id, sessionID: target.sessionID, from: store)
        #expect(source.messages.map(\.text) == ["升级好后处理这一句"])
        await app.services.executor.beginStop()()
    }

    @Test(arguments: ["withdraw", "end", "timeout", "reopen"])
    func 准备期限不续长_撤回结束退出与重连不会误派(action: String) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let request = try await workspace.said(ComposerDraft(text: "取消后不要派发"), to: target, mode: .send)
        try await app.services.executor.start()
        let waiting = try await prepared(request, in: app)
        #expect(waiting.status == .known(.preparing))
        guard waiting.status == .known(.preparing) else { await app.services.executor.beginStop()(); return }
        let due = try #require(waiting.deadlineAt)
        var repeated = try #require(try await app.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        repeated.fields["deadlineAt"] = .int(Int64((due.timeIntervalSince1970 + 3_600) * 1_000))
        repeated.fields["modifiedAt"] = .int(repeated.modifiedAt + 1)
        #expect(try await app.services.store.applyRemote([.save(repeated, systemFields: Data())]).isEmpty)
        #expect(try await app.services.store.deliveryRequest(request.id)?.deadlineAt == due)
        app.pi.update(old.id) { $0.name = "仍在升级" }
        try await sendOther(in: app)
        #expect(try await app.services.store.deliveryRequest(request.id)?.deadlineAt == due)
        switch action {
        case "withdraw":
            workspace.remove(.request(waiting))
            try await eventually("准备中的原请求撤回") { try await app.services.store.deliveryRequest(request.id) == nil }
        case "end":
            await workspace.end(target)
            #expect(try await app.services.store.outcome(of: request).status == .known(.failed))
        case "timeout":
            clock.advance(.seconds(due.timeIntervalSince(clock.now) + 1))
            try await eventually("准备到期由 Mac 确认未派发") { try await app.services.store.deliveryRequest(request.id)?.status == .known(.failed) }
        default:
            await app.services.executor.beginStop()()
            old.crash()
            try await eventually("升级时旧连接已经断开") { app.pi.session(sessionID: target.sessionID) == nil }
            clock.advance(.seconds(20))
            app.relaunch()
            try await app.services.executor.start()
            try await sendOther(in: app)
            let restored = try #require(try await app.services.store.deliveryRequest(request.id))
            #expect(restored.status == .known(.preparing) && restored.deadlineAt == due)
            #expect(app.host.calls.isEmpty)
        }
        old.close(bye: "reload")
        let ready = try await app.host.connect(target.sessionID, cwd: app.directory.path)
        if action == "reopen" {
            #expect(try await app.services.store.outcome(of: request).status == .known(.succeeded))
            #expect(ready.messages.map(\.deliveryID) == [request.id.uuidString])
        } else {
            if action != "timeout" { try await sendOther(in: app) }
            await app.services.executor.beginStop()()
            #expect(ready.messages.isEmpty)
        }
        #expect(app.host.calls.isEmpty)
        await app.services.executor.beginStop()()
    }

    @Test func 就绪事件不是派发许可_轮到它前再升级仍留在准备() async throws {
        let app = TestApp(), store = app.services.store
        let (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let request = try await workspace.said(ComposerDraft(text: "只在真实就绪时派发"), to: target, mode: .send)
        try await app.services.executor.start()
        let first = try await prepared(request, in: app)
        #expect(first.status == .known(.preparing))
        guard first.status == .known(.preparing) else { await app.services.executor.beginStop()(); return }
        let blocker = try await app.host.connect("blocking-session", cwd: app.directory.path)
        blocker.onCommand = { _, command in command["t"] as? String == "send" ? nil : ["ok": true] }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: blocker.sessionID, state: .settled)
        let blockingTarget = try #require(try await store.allPiSessionStates().first { $0.sessionID == blocker.sessionID })
        _ = try await workspace.said(ComposerDraft(text: "在另一处等ACK"), to: blockingTarget, mode: .send)
        try await eventually("另一处已接手") { blocker.messages.count == 1 }
        old.close(bye: "reload")
        let ready = try await app.host.connect(target.sessionID, cwd: app.directory.path)
        try await eventually("准备任务收到就绪事件") { try await store.deliveryRequest(request.id)?.reason != first.reason }
        app.pi.update(ready.id) { $0.upgrading = true }
        let command = try #require(blocker.commands.first { $0.json["t"] as? String == "send" })
        let id = try #require(command.json["id"] as? String)
        blocker.sendRaw("{\"t\":\"ack\",\"id\":\"\(id)\",\"ok\":true}")
        try await sendOther(in: app)
        let again = try await prepared(request, in: app)
        #expect(again.status == .known(.preparing) && again.deadlineAt == first.deadlineAt)
        #expect(ready.messages.isEmpty)
        app.pi.update(ready.id) { $0.upgrading = false }
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(ready.messages.map(\.deliveryID) == [request.id.uuidString])
        await app.services.executor.beginStop()()
    }

    @Test func 已开始操作再报升级不能回退准备重做() async throws {
        let app = TestApp(), store = app.services.store
        let id = "compound.1", sessionID = "compound"
        let link = StartedOperation(bridge: app.pi, id: id)
        app.pi.attach(PiSession(id: id, sessionID: sessionID, agent: .pi, sessionFile: nil, pid: 1,
                                cwd: app.directory, terminal: PiTerminal(), state: .settled, stateSince: .now), via: link)
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: sessionID, state: .settled)
        let target = try #require(try await store.allPiSessionStates().first { $0.sessionID == sessionID })
        defer { app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "不能把整个操作重做"), to: target, mode: .send)
        try await app.services.executor.start()
        let result = try await store.outcome(of: request)
        #expect(result.status == .known(.unconfirmed))
        app.pi.update(id) { $0.upgrading = false }
        try await sendOther(in: app)
        #expect(link.operations == 1)
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.unconfirmed))
        await app.services.executor.beginStop()()
    }
}

private final class StartedOperation: SessionLink {
    let bridge: PiBridge
    let id: String
    private(set) var operations = 0
    init(bridge: PiBridge, id: String) { self.bridge = bridge; self.id = id }
    func send(_ message: PiMessage, in _: String) async throws {
        operations += 1
        bridge.update(id) { $0.upgrading = true }
        throw PiBridgeError.upgradingExtension
    }
}
#endif
