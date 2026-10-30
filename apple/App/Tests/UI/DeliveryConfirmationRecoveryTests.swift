#if os(macOS)
import CueAgent
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

extension DeliveryConfirmationTests {
    @Test(arguments: [false, true])
    func ACK后真断线先核对最后历史_有证据则送达_没证据才静态未知(hasMessage: Bool) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        // 这里只推进业务时钟；socket 的真实关闭必须能直接结束确认，不等超时。
        let (target, ext, file) = try await session(app)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await say("最后检查这句话", to: target, in: app)
        try await app.services.executor.start()
        let phase = try await settledDispatch(request, in: app)
        #expect(phase.status == .known(.confirming))
        if hasMessage { try Self.write(ext.messages, session: target.sessionID, cwd: app.directory.path, to: file) }
        ext.crash()
        let result = try await app.services.store.outcome(of: request)
        #expect(result.status == (hasMessage ? .known(.succeeded) : .known(.unconfirmed)))
        #expect(result.failure == nil)
        #expect(ext.messages.count == 1)
        let due = try #require(phase.deadlineAt)
        #expect(clock.now < due)
        await app.services.executor.beginStop()()
    }

    @Test func App停止收齐确认任务_重开只核对且不续期_恢复消息自动接替原气泡() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let (target, ext, file) = try await session(app)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await say("重开仍只有这个意图", to: target, in: app)
        try await app.services.executor.start()
        let before = try await settledDispatch(request, in: app)
        let due = try #require(before.deadlineAt)
        #expect(before.status == .known(.confirming))
        await app.services.executor.beginStop()()
        let stopped = try #require(try await app.services.store.deliveryRequest(request.id))
        #expect(stopped.status == .known(.confirming) && stopped.deadlineAt == due)
        let services = app.relaunch()
        clock.advance(.seconds(20))
        try await services.executor.start()
        // 新发给别处的话先完成，作为重开的执行通道已恢复的屏障。
        let other = try await app.host.connect("other", cwd: app.directory.path)
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: "other", state: .settled)
        let targetB = try #require(try await services.store.allPiSessionStates().first { $0.sessionID == "other" })
        let next = try await say("另一个会话照常工作", to: targetB, in: app)
        #expect(try await services.store.outcome(of: next).status == .known(.succeeded))
        let resumed = try #require(try await services.store.deliveryRequest(request.id))
        #expect(resumed.status == .known(.confirming) && resumed.deadlineAt == due)
        try Self.write(ext.messages, session: target.sessionID, cwd: app.directory.path, to: file)
        #expect(try await services.store.outcome(of: request).status == .known(.succeeded))
        #expect(try await services.store.piMessages(of: target.sessionID).map(\.text) == ["重开仍只有这个意图"])
        #expect(ext.messages.count == 1)
        other.close(bye: "quit")
        await services.executor.beginStop()()
    }

    @Test(arguments: [false, true])
    func 发送端只收到执行阶段_确认阶段未同步就崩溃_仍能到期且允许新控制(ackAfterDeadline: Bool) async throws {
        let clock = ManualTiming()
        let mac = TestApp(timing: clock.timing)
        let phone = TestApp(timing: clock.timing, host: "phone")
        let (target, ext, _) = try await session(mac)
        ext.onCommand = { _, command in command["t"] as? String == "send" ? nil : ["ok": true] }
        defer { ext.close(bye: "quit"); mac.pi.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
        let request = try await say("确认状态丢在路上", to: target, in: mac)
        try await mac.services.executor.start()
        try await eventually("外部 Agent 已收到但尚未回 ACK") { ext.messages.count == 1 }
        let executing = try #require(try await mac.services.store.deliveryRequest(request.id))
        #expect(executing.status == .known(.executing))
        let due = try #require(executing.deadlineAt)
        let row = try #require(try await mac.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        let command = try #require(ext.commands.first { $0.json["t"] as? String == "send" })
        let ackID = try #require(command.json["id"] as? String)
        if ackAfterDeadline { clock.advance(.seconds(due.timeIntervalSince(clock.now) + 1)) }
        ext.sendRaw("{\"t\":\"ack\",\"id\":\"\(ackID)\",\"ok\":true}")
        let resolved = try await settledDispatch(request, in: mac)
        if ackAfterDeadline {
            #expect(resolved.status == .known(.unconfirmed) && resolved.deadlineAt == due)
        }
        await mac.services.executor.beginStop()()
        mac.pi.stop()
        #expect(try await phone.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        phone.services.startSpeechClock()
        if !ackAfterDeadline {
            await clock.waitForSleeper()
            clock.advance(.seconds(due.timeIntervalSince(clock.now) + 1))
        }
        try await eventually("发送端不再把执行快照当作在跑") { phone.services.speech.now >= due }
        let stillExecuting = try #require(try await phone.services.store.deliveryRequest(request.id))
        #expect(stillExecuting.status == .known(.executing))
        #expect(Speech.trip(stillExecuting, at: phone.services.speech).unconfirmedReason != nil)
        #expect(!phone.services.hasOpenDeliveries)
        #expect(ext.messages.count == 1)
    }

    @Test(arguments: [false, true])
    func 旧83已领取记录不补造期限_先查真实历史_无证据保守收敛且不重派(hasMessage: Bool) async throws {
        let app = TestApp()
        let (target, ext, file) = try await session(app)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await say("升级之前可能已经交出", to: target, in: app)
        if hasMessage {
            try Self.write([PiMessage(text: request.content, deliveryID: request.id.uuidString)], session: target.sessionID, cwd: app.directory.path, to: file)
        }
        try RawDB(app.databaseURL).exec("""
            UPDATE deliveryRequests SET status = 'executing', handledBy = '\(TestApp.hostID)';
            ALTER TABLE deliveryRequests DROP COLUMN deadlineAt;
            PRAGMA user_version = 83;
            """)
        let services = app.relaunch()
        let migrated = try #require(try await services.store.deliveryRequest(request.id))
        #expect(migrated.deadlineAt == nil)
        try await services.executor.start()
        try await eventually("旧领取事实完成一次真实核对") {
            let status = try await services.store.deliveryRequest(request.id)?.status
            return status == .known(.succeeded) || status == .known(.unconfirmed)
        }
        let result = try #require(try await services.store.deliveryRequest(request.id))
        #expect(result.status == (hasMessage ? .known(.succeeded) : .known(.unconfirmed)))
        #expect(result.deadlineAt == nil)
        #expect(ext.messages.isEmpty)
        await services.executor.beginStop()()
    }

    @Test(arguments: [false, true])
    func 确认超时静态结束_晚到历史自动纠正_不抢后来绑定且保留Cue来源(disconnected: Bool) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let (target, ext, file) = try await session(app)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        try await app.connect(.pi)
        app.services.start()
        let store = app.services.store
        let task = try await store.createTask("修复发布")
        try await store.bindSession(target.sessionID, to: task.id)
        let host = TestApp.hostID
        try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        _ = try #require(await CueTools(store: store, wait: 0).call("task", ["action": "say", "task": task.id.uuidString, "text": "核实发布结果"]))
        let request = try #require(try await store.deliveryRequests().first { $0.mode == .known(.send) })
        let before = try await settledDispatch(request, in: app)
        #expect(before.status == .known(.confirming))
        let due = try #require(before.deadlineAt)
        if disconnected { ext.crash() }
        else { clock.advance(.seconds(due.timeIntervalSince(clock.now) + 1)) }
        let uncertain = try await store.outcome(of: request)
        #expect(uncertain.status == .known(.unconfirmed))
        try await eventually("确认任务已把到期结果落盘") { try await store.deliveryRequest(request.id)?.status == .known(.unconfirmed) }
        let workspace = Workspace(services: app.services), taskID = task.id
        if disconnected {
            let other = try await app.host.connect("receipt-barrier", cwd: app.directory.path)
            await workspace.speak("继续处理另一处", to: .session(SendTarget(kind: .piSession, name: "另一处", ref: other.sessionID), host: host, mode: .send, card: nil)).value
            try await eventually("正常历史已处理断线之后的文件事件") { try await store.piCheckpoint(of: other.sessionID) != nil }
        }
        workspace.perform { try await $0.bindSession("later-session", to: taskID) }
        try await eventually("用户后来手动绑定完成") { try await store.leafSession(taskID) == "later-session" }
        try Self.write(ext.messages, session: target.sessionID, cwd: app.directory.path, to: file)
        try await eventually("常规真实历史订阅纠正超时") { try await store.deliveryRequest(request.id)?.status == .known(.succeeded) }
        #expect(try await store.leafSession(taskID) == "later-session")
        let digest = try await SessionDigest.read(target.id, sessionID: target.sessionID, from: store)
        #expect(digest.cueSent == [request.id] && digest.messages.map(\.text) == ["核实发布结果"])
        #expect(try await store.deliveryRequest(request.id)?.deadlineAt == due)
        #expect(ext.messages.count == 1)
        await app.services.executor.beginStop()()
    }
}
#endif
