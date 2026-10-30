@testable import CueStore
import Foundation
import Testing
@testable import CuePad

/// #43：投送占位防止重复，不是 Agent 当前在跑的证据。
struct RuntimeHandoffTests {
    @Test(arguments: [DeliveryMode.send, .start], ["unconfirmed", "future_ack", "pending"])
    func 未确认交接仍在推进中但不算在跑_缓存到等待期限也撤销运行断言(mode: DeliveryMode, status: String) async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), workspace = Workspace(services: app.services), store = app.services.store
        defer { app.services.cancelBackgroundWork() }
        let task = try await workspace.createTask("检查部署", in: Project.defaultID)
        let target = SendTarget(kind: .piSession, name: "部署", ref: mode == .start ? nil : "atlas")
        let text = mode == .start ? PiLaunch(project: Project.defaultID, prompt: task.body, token: UUID().uuidString).stored : task.body
        await workspace.speak(text, to: .session(target, host: "mac-worker", mode: mode, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first)
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        }
        let before = try await now()
        #expect(before.tally.moving == 1 && before.advancing == 1)
        if status == "pending" {
            clock.advance(.seconds(Speech.sendLimit + Speech.receiptLimit + 1))
        } else {
            var row = try #require(try await store.syncRow(recordName: request.id.uuidString.lowercased()))
            row.fields["status"] = .text(status)
            row.fields["modifiedAt"] = .int(Int64(Date.now.addingTimeInterval(1).timeIntervalSince1970 * 1000))
            #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        let uncertain = try await now()
        #expect(uncertain.advancing == 1 && uncertain.tally.moving == 0 && uncertain.items.first?.kind == .unconfirmed)
        #expect(uncertain.isLive && !uncertain.hasConfirmedActivity)
        let timedOut = before.shown(at: before.at + Speech.sendLimit + Speech.receiptLimit + 1)
        #expect(timedOut.tally.moving == 0 && timedOut.isLive && !timedOut.hasConfirmedActivity)
        #expect(try await store.handoffRequests(for: [task.id])[task.id]?.map(\.id) == [request.id])
    }

    @Test func 开会话受理不等于正在运行_真实会话报告到来才计在跑() async throws {
        let app = TestApp(), workspace = Workspace(services: app.services), store = app.services.store
        let task = try await workspace.createTask("检查部署", in: Project.defaultID)
        let launch = PiLaunch(project: Project.defaultID, prompt: task.body, token: UUID().uuidString)
        await workspace.speak(launch.stored, to: .session(SendTarget(kind: .piSession, name: "部署"), host: "mac-worker", mode: .start, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first)
        var row = try #require(try await store.syncRow(recordName: request.id.uuidString.lowercased()))
        row.fields["status"] = .text("succeeded")
        row.fields["modifiedAt"] = .int(Int64(Date.now.addingTimeInterval(1).timeIntervalSince1970 * 1000))
        #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(), local: .init(waiting: nil, here: nil))
        }
        let accepted = try await now()
        #expect(accepted.advancing == 1 && accepted.tally.moving == 0 && accepted.items.first?.kind == .unconfirmed)
        #expect(accepted.isLive && !accepted.hasConfirmedActivity)
        let recorder = try await app.runtimeRecorder(on: "mac-worker")
        try await recorder.update(sessionID: "launched", state: .thinking, title: "检查部署", launchToken: launch.token, hosted: true)
        let confirmed = try await now()
        #expect(confirmed.advancing == 1 && confirmed.tally.moving == 1 && confirmed.hasConfirmedActivity && !confirmed.unconfirmed)
    }

}
