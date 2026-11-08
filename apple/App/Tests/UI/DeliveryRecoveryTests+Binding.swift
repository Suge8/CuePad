#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi
@testable import CueStore

extension DeliveryRecoveryTests {
    @Test(arguments: [false, true])
    func 手机明确关联之后_另一台Mac的旧ACK与卡片云回声不能抢回(unbind: Bool) async throws {
        let mac = TestApp(), phone = TestApp(host: "phone")
        let store = mac.services.store, remote = phone.services.store
        defer { mac.pi.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
        let ext = try await mac.host.connect("old-session", cwd: mac.directory.path)
        defer { ext.close(bye: "quit") }
        ext.onCommand = { _, command in command["t"] as? String == "send" ? nil : ["ok": true] }
        let recorder = try await mac.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled)
        let workspace = Workspace(services: mac.services)
        let task = try await workspace.createTask("检查发布", in: Project.defaultID)
        await workspace.speak("检查发布", to: .session(
            SendTarget(kind: .piSession, name: "旧会话", ref: ext.sessionID), host: TestApp.hostID, mode: .send, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first)
        for id in [task.id, request.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await remote.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await PiStateRecorder(store: remote, hostID: TestApp.hostID).update(sessionID: "chosen-session", state: .thinking)
        let phoneWorkspace = Workspace(services: phone.services)
        let taskID = task.id
        phoneWorkspace.perform { try await $0.bindSession("chosen-session", to: taskID) }
        try await eventually("手机纯关联完成") { try await remote.card(taskID)?.piSessionID == "chosen-session" }
        if unbind {
            phoneWorkspace.perform { try await $0.unbindSession(from: taskID) }
            try await eventually("手机解绑完成") { try await remote.card(taskID)?.piSessionID == nil }
        }
        try await mac.services.executor.start()
        try await eventually("旧请求已经交出，等待真实 ACK") { ext.messages.count == 1 }
        let command = try #require(ext.commands.first { $0.json["t"] as? String == "send" })
        let ack = try #require(command.json["id"] as? String)
        ext.sendRaw("{\"t\":\"ack\",\"id\":\"\(ack)\",\"ok\":true}")
        try await eventually("Mac 完成旧回执关联") { try await store.card(taskID)?.piSessionID == ext.sessionID }
        for id in [request.id, task.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await remote.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        #expect(try await remote.card(taskID)?.piSessionID == (unbind ? nil : "chosen-session"))
        #expect(try await remote.deliveryRequests().count == 1)
        #expect(ext.messages.map(\.text) == ["检查发布"])
        await mac.services.executor.beginStop()()
    }
}
#endif
