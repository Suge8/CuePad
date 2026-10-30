#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

extension DeliveryConfirmationTests {
    @Test func 真实消息先于ACK被历史收下_晚到确认阶段不能降级或改写期限() async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext, file) = try await session(app)
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "send" { return nil }
            if command["t"] as? String == "end" { ext?.closeAfterReply(bye: "quit") }
            return ["ok": true]
        }
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        try await app.connect(.pi)
        app.services.start()
        let request = try await say("真实消息比ACK先回来", to: target, in: app)
        try await eventually("Agent 收到请求") { ext.messages.count == 1 }
        try Self.write(ext.messages, session: target.sessionID, cwd: app.directory.path, to: file)
        try await eventually("正常历史订阅先确认用户消息") { try await store.deliveryRequest(request.id)?.status == .known(.succeeded) }
        let positive = try #require(try await store.deliveryRequest(request.id))
        let command = try #require(ext.commands.first { $0.json["t"] as? String == "send" })
        let ackID = try #require(command.json["id"] as? String)
        ext.sendRaw("{\"t\":\"ack\",\"id\":\"\(ackID)\",\"ok\":true}")
        await Workspace(services: app.services).end(target)
        let end = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        #expect(try await store.outcome(of: end).status == .known(.succeeded))
        let final = try #require(try await store.deliveryRequest(request.id))
        #expect(final.status == .known(.succeeded) && final.deadlineAt == positive.deadlineAt)
        #expect(try await store.piMessages(of: target.sessionID).map(\.text) == ["真实消息比ACK先回来"])
        #expect(ext.messages.count == 1)
        await app.services.executor.beginStop()()
    }

    @Test func 同阶段较新同步快照与重开不能延长确认窗口() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let (target, ext, _) = try await session(app)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await say("截止时间不随版本续长", to: target, in: app)
        try await app.services.executor.start()
        let confirming = try await settledDispatch(request, in: app)
        let due = try #require(confirming.deadlineAt)
        var echo = try #require(try await app.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        echo.fields["modifiedAt"] = .int(echo.modifiedAt + 10_000)
        echo.fields["deadlineAt"] = .int(Int64(due.addingTimeInterval(120).timeIntervalSince1970 * 1000))
        #expect(try await app.services.store.applyRemote([.save(echo, systemFields: Data())]).isEmpty)
        #expect(try await app.services.store.deliveryRequest(request.id)?.deadlineAt == due)
        await app.services.executor.beginStop()()
        let services = app.relaunch()
        clock.advance(.seconds(20))
        try await services.executor.start()
        #expect(try await services.store.deliveryRequest(request.id)?.deadlineAt == due)
        #expect(ext.messages.count == 1)
        await services.executor.beginStop()()
    }

    @Test(arguments: [DeliveryMode.retry, .end], ["executing", "confirming"])
    func 持久阶段期限已过而接收端没写回_再点控制新增一个意图(mode: DeliveryMode, status: String) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), store = app.services.store
        defer { app.services.cancelBackgroundWork() }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: "atlas", state: .error, detail: "network", failure: .network)
        let target = try #require(try await store.allPiSessionStates().first)
        let workspace = Workspace(services: app.services)
        if mode == .retry { await workspace.retry(target).value } else { await workspace.end(target) }
        let first = try #require(try await store.deliveryRequests().first)
        var phase = try #require(try await store.syncRow(recordName: first.id.uuidString.lowercased()))
        phase.fields["status"] = .text(status)
        phase.fields["handledBy"] = .text(TestApp.hostID)
        phase.fields["deadlineAt"] = .int(Int64(clock.now.addingTimeInterval(-1).timeIntervalSince1970 * 1000))
        phase.fields["modifiedAt"] = .int(phase.modifiedAt + 1)
        #expect(try await store.applyRemote([.save(phase, systemFields: Data())]).isEmpty)
        let expired = try #require(try await store.deliveryRequest(first.id))
        #expect(Speech.trip(expired, at: app.services.speech).unconfirmedReason != nil)
        if mode == .retry { await workspace.retry(target).value } else { await workspace.end(target) }
        let requests = try await store.deliveryRequests()
        #expect(requests.count == 2)
        #expect(requests.contains { $0.id == first.id && $0.status.rawValue == status })
        #expect(requests.filter { $0.id != first.id }.count == 1)
    }
    @Test(arguments: [false, true])
    func 启动Agent不是写盘确认_确认窗口从交出后起算_退出不能遗留启动或重开旧请求(cancelOpening: Bool) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), workspace = Workspace(services: app.services)
        defer {
            for ext in app.host.extensions.values { ext.close(bye: "quit") }
            app.pi.stop(); app.services.cancelBackgroundWork()
        }
        try await app.offersPi()
        let gate = AsyncStream<Void>.makeStream()
        app.host.openingGate = gate.stream
        app.host.writesMessages = false
        let opening = Task {
            try await workspace.startSession(in: Project.defaultID, prompt: "只开一次", title: "检查", card: nil, agent: .pi) { _ in }
        }
        defer { opening.cancel() }
        try await eventually("表单写下开会话意图") { try await app.services.store.deliveryRequests().count == 1 }
        let request = try #require(try await app.services.store.deliveryRequests().first)
        try await app.services.executor.start()
        try await eventually("开始起 Agent") { !app.host.calls.isEmpty }
        let executing = try #require(try await app.services.store.deliveryRequest(request.id))
        #expect(executing.status == .known(.executing))
        clock.advance(.seconds(20))
        #expect(Speech.trip(executing, at: .always(at: clock.now, localHost: TestApp.hostID)).inTransit)
        if cancelOpening {
            await app.services.executor.beginStop()()
            #expect(app.host.extensions.isEmpty)
            try await app.services.executor.start()
            try await eventually("旧启动只保守收敛，不再开进程") {
                try await app.services.store.deliveryRequest(request.id)?.status == .known(.unconfirmed) || app.host.calls.count > 1
            }
            #expect(try await app.services.store.deliveryRequest(request.id)?.status == .known(.unconfirmed))
            #expect(app.host.calls.count == 1 && app.host.extensions.isEmpty)
            #expect(try await app.services.store.deliveryRequest(request.id)?.deadlineAt == executing.deadlineAt)
        } else {
            gate.continuation.yield()
            let confirming = try await settledDispatch(request, in: app)
            #expect(confirming.status == .known(.confirming))
            clock.advance(.seconds(41))
            #expect(Speech.trip(confirming, at: .always(at: clock.now, localHost: TestApp.hostID)).inTransit)
            clock.advance(.seconds(20))
            #expect(try await app.services.store.outcome(of: request).status == .known(.unconfirmed))
            #expect(app.host.calls.count == 1)
        }
        opening.cancel()
        _ = await opening.result
        await app.services.executor.beginStop()()
    }

}
#endif
