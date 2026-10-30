#if os(macOS)
import CryptoKit
@testable import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

extension UpgradePreparationTests {
    @Test(arguments: ["withdraw", "end", "offline"])
    func 手机读准备句式_不计入在跑_撤回结束由执行Mac核对(action: String) async throws {
        let clock = ManualTiming()
        let mac = TestApp(timing: clock.timing), phone = TestApp(timing: clock.timing, host: "phone")
        let (target, old) = try await oldSession(mac)
        defer { old.crash(); mac.pi.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
        let workspace = Workspace(services: phone.services)
        let request = try await workspace.said(ComposerDraft(text: "在手机上撤回升级等待"), to: target, mode: .send)
        let outbound = try #require(try await phone.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await mac.services.store.applyRemote([.save(outbound, systemFields: Data())]).isEmpty)
        try await mac.services.executor.start()
        _ = try await prepared(request, in: mac)
        let pending = try #require(try await mac.services.store.syncRow(recordName: outbound.id))
        #expect(try await phone.services.store.applyRemote([.save(pending, systemFields: Data())]).isEmpty)
        let received = try #require(try await phone.services.store.deliveryRequest(request.id))
        #expect(received.status == .known(.preparing))
        #expect(received.reason == ShownText("会话扩展正在升级"))
        let trip = Speech.trip(received, at: phone.services.speech)
        guard case .preparing(let reason) = trip else { Issue.record("手机应显示准备，而不是发送中或失败"); return }
        #expect(reason.contains("尚未派发") && reason.contains("升级"))
        #expect(!trip.inTransit && trip.failure == nil && trip.unconfirmedReason == nil)
        let shown = PiShown(target, delivery: received, at: phone.services.speech)
        #expect(!shown.isRunning && shown.mark == .icon)
        let look = TaskAgentLook(shown, line: nil)
        #expect(look.title == reason && look.note == nil)
        #expect(TaskNext(shown: shown, session: target, startable: nil)?.agentBusy == false)
        if action == "end" {
            await workspace.end(target)
            try #require(try await phone.services.store.deliveryRequest(request.id)?.status == .known(.preparing))
            let end = try #require(try await phone.services.store.deliveryRequests().first { $0.mode == .known(.end) })
            let row = try #require(try await phone.services.store.syncRow(recordName: end.id.uuidString.lowercased()))
            #expect(try await mac.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
            try await eventually("执行Mac证明准备中的原请求不会再派发") { try await mac.services.store.deliveryRequest(request.id)?.status == .known(.failed) }
            let stopped = try #require(try await mac.services.store.syncRow(recordName: outbound.id))
            #expect(try await phone.services.store.applyRemote([.save(stopped, systemFields: Data())]).isEmpty)
            #expect(try await phone.services.store.deliveryRequest(request.id)?.reason == DeliveryPreparation.abandoned)
        } else {
            workspace.remove(.request(received))
            try await eventually("手机写下撤回控制意图") { try await phone.services.store.deliveryRequests().contains { $0.mode == .known(.withdraw) } }
            let cancellation = try #require(try await phone.services.store.deliveryRequests().first { $0.mode == .known(.withdraw) })
            if action == "offline" {
                clock.advance(.seconds(Speech.receiptLimit + 1))
                try await eventually("没收到撤回证明，只能报告未确认") { workspace.notice?.isError == true }
                #expect(try await phone.services.store.deliveryRequest(request.id)?.status == .known(.preparing))
                #expect(old.messages.isEmpty)
                await mac.services.executor.beginStop()()
                return
            }
            let cancelRow = try #require(try await phone.services.store.syncRow(recordName: cancellation.id.uuidString.lowercased()))
            #expect(try await mac.services.store.applyRemote([.save(cancelRow, systemFields: Data())]).isEmpty)
            #expect(try await mac.services.store.outcome(of: cancellation).status == .known(.succeeded))
            #expect(try await mac.services.store.deliveryRequest(request.id) == nil)
            let receipt = try #require(try await mac.services.store.syncRow(recordName: cancelRow.id))
            #expect(try await phone.services.store.applyRemote([.save(receipt, systemFields: Data())]).isEmpty)
            try await eventually("执行Mac证明未交出后手机才移除原请求") { try await phone.services.store.deliveryRequest(request.id) == nil }
            #expect(workspace.notice?.isError != true)
        }
        old.close(bye: "reload")
        let ready = try await mac.host.connect(target.sessionID, cwd: mac.directory.path)
        try await sendOther(in: mac)
        #expect(ready.messages.isEmpty && mac.host.calls.isEmpty)
        await mac.services.executor.beginStop()()
    }

    @Test func 准备保留交接占位_不授权新任务活动_真实送达才关联会话() async throws {
        let app = TestApp(), store = app.services.store
        let (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let task = try await workspace.createTask("升级就绪再交接", in: Project.defaultID)
        let request = try await workspace.said(ComposerDraft(text: task.body), to: target, mode: .send, card: task.id)
        try await app.services.executor.start()
        _ = try await prepared(request, in: app)
        let item = try #require(try await store.cueBoard().tasks.first { $0.id == task.id })
        #expect(!item.isActive && !item.reaching)
        #expect(try await store.cueTally().advancing.allSatisfy { $0.task?.id != task.id })
        #expect(try await store.handoffRequests(for: [task.id])[task.id]?.map(\.id) == [request.id])
        #expect(try await store.cueTaskDetail(task.id).leaves.first?.handoffs.map(\.id) == [request.id])
        #expect(try await store.card(task.id)?.piSessionID == nil)
        old.close(bye: "reload")
        let ready = try await app.host.connect(target.sessionID, cwd: app.directory.path)
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(try await store.card(task.id)?.piSessionID == target.sessionID)
        #expect(ready.messages.map(\.deliveryID) == [request.id.uuidString])
        await app.services.executor.beginStop()()
    }

    @Test func 附件准备后的历史会话仍可恢复_不是等待旧进程重连() async throws {
        let app = TestApp(), store = app.services.store
        defer { app.pi.stop(); app.services.cancelBackgroundWork() }
        try FileManager.default.createDirectory(at: app.directory, withIntermediateDirectories: true)
        let file = app.directory.appending(path: "sleeping.jsonl")
        try await store.upsertPiSession(IndexedSession(id: "sleeping", path: file.path, cwd: app.directory.path,
                                                    title: "历史会话", lastActivityAt: .now), host: TestApp.hostID)
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: "sleeping", state: .ended)
        let target = try #require(try await store.allPiSessionStates().first)
        let data = Data("等待下载的附件".utf8), source = app.directory.appending(path: "资料.txt")
        try data.write(to: source)
        let key = AttachmentKey.make(hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), format: "txt")
        let arrival = AsyncStream<Void>.makeStream()
        app.sync.fetching.withLock {
            $0 = { [files = store.files, ready = arrival.stream] wanted in
                for await _ in ready { break }
                _ = try files.store(fileAt: source)
                return try #require(files.fileURL(for: wanted))
            }
        }
        let request = try await Workspace(services: app.services).said(
            ComposerDraft(text: "恢复后读附件", files: [DraftFile(key: key, name: "资料.txt")]), to: target, mode: .send)
        try await app.services.executor.start()
        try await eventually("历史会话先准备附件") { try await store.deliveryRequest(request.id)?.deadlineAt != nil }
        #expect(try await store.deliveryRequest(request.id)?.status == .known(.pending))
        #expect(app.host.calls.isEmpty)
        arrival.continuation.yield()
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        #expect(app.host.calls == [.resume(sessionFile: file.path, directory: app.directory.path)])
        #expect(app.host.extensions["sleeping"]?.messages.map(\.deliveryID) == [request.id.uuidString])
        await app.services.executor.beginStop()()
    }

    @Test(arguments: ["bad_request", "no_auth"])
    func 协议拒绝和授权失败不成为升级等待(error: String) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let ext = try await app.host.connect("refused", cwd: app.directory.path, extensionVersion: PiWire.oldestExtension)
        ext.onCommand = { _, command in command["t"] as? String == "send" ? ["ok": false, "error": error] : ["ok": true] }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled)
        let target = try #require(try await app.services.store.allPiSessionStates().first)
        defer { ext.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "不把拒绝当升级"), to: target, mode: .send)
        try await app.services.executor.start()
        try await eventually("收到拒绝，不等待升级") {
            guard let current = try await app.services.store.deliveryRequest(request.id) else { return false }
            return [.known(.failed), .known(.confirming), .known(.unconfirmed)].contains(current.status)
        }
        if error == "bad_request" { clock.advance(.seconds(Speech.receiptLimit + 1)) }
        let result = try await app.services.store.outcome(of: request)
        #expect(result.status == (error == "no_auth" ? .known(.failed) : .known(.unconfirmed)))
        #expect(ext.messages.count == 1)
        app.pi.update(ext.id) { $0.upgrading = false }
        #expect(try await app.services.store.deliveryRequests().filter { $0.mode == .known(.send) }.map(\.id) == [request.id])
        await app.services.executor.beginStop()()
    }

    @Test func 准备将到期时就绪_领取后进入独立执行期限_不误判未派发() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "最后一刻就绪也只送一次"), to: target, mode: .send)
        try await app.services.executor.start()
        let waiting = try await prepared(request, in: app)
        let due = try #require(waiting.deadlineAt)
        clock.advance(.seconds(due.timeIntervalSince(clock.now) - 1))
        old.close(bye: "reload")
        let file = app.directory.appending(path: "near-deadline.jsonl")
        var options = FakeExtension.Options(cwd: app.directory.path)
        options.sessionFile = file.path
        let ready = FakeExtension(directory: app.socketDirectory, sessionID: target.sessionID, options: options)
        ready.onCommand = { _, command in command["t"] as? String == "send" ? nil : ["ok": true] }
        try ready.start()
        defer { ready.crash() }
        try await eventually("准备结束，消息已交给现有会话") { ready.messages.count == 1 }
        let executing = try #require(try await app.services.store.deliveryRequest(request.id))
        #expect(executing.status == .known(.executing) && executing.deadlineAt.map { $0 > due } == true)
        clock.advance(.seconds(2))
        #expect(Speech.trip(executing, at: .always(at: clock.now)).inTransit)
        try DeliveryConfirmationTests.write(ready.messages, session: target.sessionID, cwd: app.directory.path, to: file)
        let command = try #require(ready.commands.first { $0.json["t"] as? String == "send" })
        let id = try #require(command.json["id"] as? String)
        ready.sendRaw("{\"t\":\"ack\",\"id\":\"\(id)\",\"ok\":true}")
        #expect(try await app.services.store.outcome(of: request).status == .known(.succeeded))
        #expect(ready.messages.map(\.deliveryID) == [request.id.uuidString])
        await app.services.executor.beginStop()()
    }

    @Test func 现场旧失败请求在86升级和就绪后保持原样_不补发() async throws {
        let app = TestApp(), (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let request = try await Workspace(services: app.services).said(ComposerDraft(text: "过去已经报失败的那句"), to: target, mode: .send)
        var historical = try #require(try await app.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        let reason = ShownText.verbatim("旧版扩展升级拒绝的原始原因")
        historical.fields["status"] = .text("not_delivered")
        historical.fields["handledBy"] = .text(TestApp.hostID)
        historical.fields["failure"] = .text(reason.stored)
        #expect(try await app.services.store.applyRemote([.save(historical, systemFields: Data())]).isEmpty)
        try RawDB(app.databaseURL).exec("PRAGMA user_version = 85")
        app.relaunch()
        #expect(CueStore.schemaVersion(of: app.databaseURL) == 86)
        try await app.services.executor.start()
        old.close(bye: "reload")
        let ready = try await app.host.connect(target.sessionID, cwd: app.directory.path)
        try await sendOther(in: app)
        let unchanged = try #require(try await app.services.store.deliveryRequest(request.id))
        #expect(unchanged.status == .known(.failed) && unchanged.reason == reason)
        #expect(ready.messages.isEmpty && app.host.calls.isEmpty)
        await app.services.executor.beginStop()()
    }
}
#endif
