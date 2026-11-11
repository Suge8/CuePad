#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge
@testable import CueStore

extension DeliveryRecoveryTests {
    @Test(arguments: [false, true])
    func 手机明确关联之后_另一台Mac的旧ACK与卡片云回声不能抢回(unbind: Bool) async throws {
        let mac = TestApp(), phone = TestApp(host: "phone")
        let store = mac.services.store, remote = phone.services.store
        defer { mac.bridge.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
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
        try await StateRecorder(store: remote, hostID: TestApp.hostID).update(sessionID: "chosen-session", state: .thinking)
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
extension DeliveryRecoveryTests {
    @Test func 同一关联意图_正文编辑与送达乱序重放后两端收敛() async throws {
        let mac = TestApp(), phone = TestApp(host: "phone")
        let store = mac.services.store, remote = phone.services.store
        defer { mac.bridge.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
        let ext = try await mac.host.connect("audit-session", cwd: mac.directory.path)
        defer { ext.close(bye: "quit") }
        ext.onCommand = { _, command in command["t"] as? String == "send" ? nil : ["ok": true] }
        let recorder = try await mac.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled)
        let workspace = Workspace(services: mac.services)
        let task = try await workspace.createTask("检查发布", in: Project.defaultID)
        await workspace.speak("检查发布", to: .session(
            SendTarget(kind: .piSession, name: "会话", ref: ext.sessionID), host: TestApp.hostID, mode: .send, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first)
        for id in [task.id, request.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await remote.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await mac.services.executor.start()
        try await eventually("等待投送") { ext.messages.count == 1 }
        let command = try #require(ext.commands.first { $0.json["t"] as? String == "send" })
        let ack = try #require(command.json["id"] as? String)
        ext.sendRaw("{\"t\":\"ack\",\"id\":\"\(ack)\",\"ok\":true}")
        try await eventually("回执兑现关联") { try await store.card(task.id)?.piSessionID == ext.sessionID }
        try await remote.updateCard(task.id) { $0.body = "检查发布\n手机补充" }
        var edited = try #require(try await remote.syncRow(recordName: task.id.uuidString.lowercased()))
        let acknowledged = try #require(try await store.syncRow(recordName: task.id.uuidString.lowercased()))
        // 手机时钟较快：正文新版本必须获胜，不能连带抹掉同一意图已兑现的会话。
        edited.fields["modifiedAt"] = .int(acknowledged.modifiedAt + 1_000)
        #expect(try await store.applyRemote([.save(edited, systemFields: Data())]).isEmpty)
        #expect(try await store.card(task.id)?.body == "检查发布\n手机补充")
        #expect(try await store.card(task.id)?.piSessionID == ext.sessionID)
        let merged = try #require(try await store.syncRow(recordName: task.id.uuidString.lowercased()))
        for device in [store, remote] {
            for row in [acknowledged, edited, merged, edited, acknowledged] {
                #expect(try await device.applyRemote([.save(row, systemFields: Data())]).isEmpty)
            }
            #expect(try await device.card(task.id)?.body == "检查发布\n手机补充")
            #expect(try await device.card(task.id)?.piSessionID == ext.sessionID)
        }
        #expect(ext.messages.map(\.text) == ["检查发布"])
        await mac.services.executor.beginStop()()
    }
}
#endif
