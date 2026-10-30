#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

/// #43：ACK 后由程序核对真实历史；发送端有界等待，不借重投探测。
@MainActor
struct DeliveryConfirmationTests {
    func session(_ app: TestApp) async throws -> (PiSessionState, FakeExtension, URL) {
        let id = UUID().uuidString.lowercased()
        let file = app.piPaths.sessionsDirectory.appending(path: "--confirmation--/\(id).jsonl")
        try Self.write([], session: id, cwd: app.directory.path, to: file)
        let ext = try await app.host.connect(id, cwd: app.directory.path, sessionFile: file.path)
        ext.onCommand = { _, _ in ["ok": true] }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: id, state: .settled)
        return (try #require(try await app.services.store.allPiSessionStates().first { $0.sessionID == id }), ext, file)
    }

    func say(_ text: String, to target: PiSessionState, in app: TestApp) async throws -> DeliveryRequest {
        let box = app.services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: text)
        await Workspace(services: app.services).speak(to: .session(target, mode: .send), from: box) { $0.stored }.value
        return try #require(try await app.services.store.deliveryRequests().first { $0.content == text })
    }

    nonisolated static func write(_ messages: [PiMessage], session: String, cwd: String, to file: URL) throws {
        let now = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(.now)
        var rows: [[String: Any]] = [["type": "session", "version": 3, "id": session, "timestamp": now, "cwd": cwd]]
        for (index, message) in messages.enumerated() {
            rows.append([
                "type": "message", "id": "user-\(index)", "timestamp": now,
                "message": ["role": "user", "content": message.text, "cuepadDelivery": message.deliveryID ?? ""],
            ])
        }
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(0x0A) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func settledDispatch(_ request: DeliveryRequest, in app: TestApp) async throws -> DeliveryRequest {
        try await eventually("派发阶段结束") {
            let status = try await app.services.store.deliveryRequest(request.id)?.status.rawValue
            return status != "pending" && status != "executing"
        }
        return try #require(try await app.services.store.deliveryRequest(request.id))
    }

    @Test(arguments: [false, true])
    func ACK前后真实用户消息都自动确认_不等回答_不闪未确认(beforeACK: Bool) async throws {
        let app = TestApp(), store = app.services.store
        let (target, ext, file) = try await session(app)
        defer { ext.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        if beforeACK {
            let cwd = app.directory.path, session = target.sessionID
            ext.onCommand = { _, command in
                if command["t"] as? String == "send" {
                    let message = PiMessage(text: command["text"] as? String ?? "", deliveryID: command["deliveryId"] as? String)
                    do { try Self.write([message], session: session, cwd: cwd, to: file) }
                    catch { return ["ok": false, "error": "failed: \(error)"] }
                }
                return ["ok": true]
            }
        }
        let request = try await say("只等我这句话落盘", to: target, in: app)
        try await app.services.executor.start()
        let waiting = try await settledDispatch(request, in: app)
        #expect(Speech.trip(waiting, at: .always(localHost: TestApp.hostID)).unconfirmedReason == nil)
        if !beforeACK {
            #expect(Speech.trip(waiting, at: .always(localHost: TestApp.hostID)).inTransit)
            try Self.write(ext.messages, session: target.sessionID, cwd: app.directory.path, to: file)
        }
        let arrived = try await store.outcome(of: request)
        #expect(arrived.status == .known(.succeeded))
        #expect(try await store.piMessages(of: target.sessionID).map(\.text) == ["只等我这句话落盘"])
        #expect(ext.messages.count == 1)
        await app.services.executor.beginStop()()
    }

    @Test(arguments: [false, true])
    func 一处等历史不占投送通道_另一处能先收到话(uploadStuck: Bool) async throws {
        let app = TestApp(), store = app.services.store
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let (first, extA, _) = try await session(app)
        let (second, extB, fileB) = try await session(app)
        defer { extA.close(bye: "quit"); extB.close(bye: "quit"); app.pi.stop(); app.services.cancelBackgroundWork() }
        let cwd = app.directory.path, sessionB = second.sessionID
        extB.onCommand = { _, command in
            if command["t"] as? String == "send" {
                do {
                    try Self.write([PiMessage(text: command["text"] as? String ?? "", deliveryID: command["deliveryId"] as? String)], session: sessionB, cwd: cwd, to: fileB)
                } catch { return ["ok": false, "error": "failed: \(error)"] }
            }
            return ["ok": true]
        }
        let pendingA = try await say("等第一处写盘", to: first, in: app)
        if uploadStuck { app.sync.sendingGate.withLock { $0 = gate.stream } }
        try await app.services.executor.start()
        _ = try await settledDispatch(pendingA, in: app)
        let sendingB = Workspace(services: app.services).speak("第二处先完成", to: .session(second, mode: .send))
        defer { sendingB.cancel() }
        try await eventually("写下第二处的新意图") { try await store.deliveryRequests().contains { $0.content == "第二处先完成" } }
        let pendingB = try #require(try await store.deliveryRequests().first { $0.content == "第二处先完成" })
        try await eventually("第二处收到话，不等第一处的历史或上传") { extB.messages.count == 1 }
        #expect(try await store.outcome(of: pendingB).status == .known(.succeeded))
        let waitingA = try #require(try await store.deliveryRequest(pendingA.id))
        #expect(Speech.trip(waitingA, at: .always(localHost: TestApp.hostID)).inTransit)
        #expect(extA.messages.count == 1 && extB.messages.count == 1)
        await app.services.executor.beginStop()()
    }

    @Test func 接收App在ACK后停止且不重开_发送端断网也按持久期限结束等待() async throws {
        let clock = ManualTiming()
        let mac = TestApp(timing: clock.timing), phone = TestApp(timing: clock.timing, host: "phone")
        let (target, ext, _) = try await session(mac)
        defer { ext.close(bye: "quit"); mac.pi.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
        let request = try await say("不依赖接收端活着", to: target, in: mac)
        try await mac.services.executor.start()
        let confirming = try await settledDispatch(request, in: mac)
        #expect(confirming.status.rawValue == "confirming")
        let row = try #require(try await mac.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await phone.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        phone.services.startSpeechClock()
        let due = try #require(Speech.deadline(confirming, at: .always(at: clock.now)))
        await mac.services.executor.beginStop()()
        mac.pi.stop()
        await clock.waitForSleeper()
        clock.advance(.seconds(due.timeIntervalSince(clock.now) + 1))
        try await eventually("发送端自己的时钟结束等待") { phone.services.speech.now >= due }
        let received = try #require(try await phone.services.store.deliveryRequest(request.id))
        #expect(Speech.trip(received, at: phone.services.speech).unconfirmedReason != nil)
        #expect(Speech.trip(received, at: phone.services.speech).failure == nil)
        #expect(ext.messages.count == 1)
        let workspace = Workspace(services: phone.services)
        let box = phone.services.settings.replyDraftBinding(for: target.id)
        await workspace.resend(.request(received), restoringInto: box).value
        #expect(workspace.notice?.isError == true)
        #expect(try await phone.services.store.deliveryRequests().count == 1)
        await workspace.sayAgain(.request(received), restoringInto: box).value
        let requests = try await phone.services.store.deliveryRequests()
        #expect(requests.count == 2 && requests.contains { $0.id == request.id && $0.status.rawValue == "confirming" })
    }
}
#endif
