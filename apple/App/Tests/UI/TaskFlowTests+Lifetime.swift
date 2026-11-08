@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension TaskFlowTests {
    @Test func 明确退回待办保留已完成子任务_新子任务推进才重新开始父任务() async throws {
        let workspace = Workspace(services: rig.services)
        let task = try await workspace.createTask("发布", in: Project.defaultID)
        let done = try await store.createTask("备份", under: task.id)
        let next = try await store.createTask("上传", under: task.id)
        try await workspace.complete(done.id)
        #expect(try await store.card(task.id)?.status == .inProgress)
        let id = task.id
        workspace.perform { try await $0.setStatus(id, .todo) }
        try await eventually("明确回到待办") { try await store.card(id)?.status == .todo }
        #expect(try await store.card(done.id)?.status == .done)
        #expect(try await TaskBoard.read(from: store).todo.map(\.id) == [id])
        #expect(try await CueDigest.read(from: store).advancing == 0)
        let step = next.id
        workspace.perform { try await $0.setStatus(step, .inProgress) }
        try await eventually("新的一步推进父任务") { try await store.card(id)?.status == .inProgress }
        #expect(try await TaskBoard.read(from: store).advancing.compactMap(\.item?.id) == [id])
        #expect(try await CueDigest.read(from: store).advancing == 1)
        #expect(try await store.cueBoard().active.isEmpty)
    }

    @Test(arguments: ["complete", "archive", "trash"])
    func 纯绑定借用托管会话_重复关联不写入_离开看板不结束(action: String) async throws {
        let workspace = Workspace(services: rig.services)
        let task = try await workspace.createTask("跟进语音", in: Project.defaultID)
        let recorder = try await rig.runtimeRecorder(on: "remote-mac")
        try await recorder.update(sessionID: "voice", state: .thinking, hosted: true)
        let id = task.id
        workspace.perform { try await $0.bindSession("voice", to: id) }
        try await eventually("纯关联完成") { try await store.card(id)?.piSessionID == "voice" }
        let first = try #require(try await store.card(id))
        try await store.bindSession("voice", to: id)
        #expect(try await store.card(id) == first)
        #expect(try await store.deliveryRequests().isEmpty)
        #expect(try await TaskBoard.read(from: store).advancing.map(\.id) == ["task/\(id.uuidString)"])
        switch action {
        case "archive": try await workspace.archive(id)
        case "trash": try await workspace.trash(id)
        default: try await workspace.complete(id)
        }
        #expect(try await store.deliveryRequests().isEmpty)
        #expect(try await store.piSessions(sessionIDs: ["voice"])["voice"]?.state.state == .known(.thinking))
    }

    #if os(macOS)
    @Test func 自己创建的会话_清理投送并重开后仍收尾_执行前新借用阻止自动结束_明确结束仍有效() async throws {
        try await rig.offersPi()
        try await store.setDirectory(rig.directory.path, for: Project.defaultID)
        let changes = rig.pi.changes()
        let recording = Task { try await rig.services.consumePiChanges(changes) }
        defer { recording.cancel(); rig.pi.stop(); rig.services.cancelBackgroundWork() }
        try await rig.services.executor.start()
        let workspace = Workspace(services: rig.services)
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        workspace.startFresh(task)
        let started = try await eventually(store, { try $0.card(task.id) }) { $0?.piSessionID != nil }
        let sessionID = try #require(started?.piSessionID)
        let launch = try #require(try await store.deliveryRequests().first { $0.mode == .known(.start) })
        #expect(try await store.outcome(of: launch).status == .known(.succeeded))
        let ext = try #require(rig.host.extensions[sessionID])
        defer { ext.close(bye: "quit") }
        await rig.services.executor.beginStop()()
        try await store.deleteDelivery(launch.id)
        let services = rig.relaunch(), reopened = Workspace(services: services)
        let phone = TestApp(host: "phone"), phoneWorkspace = Workspace(services: phone.services)
        for id in [task.id, PiSessionState.recordID(sessionID: sessionID)] {
            let row = try #require(try await services.store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await phone.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await phoneWorkspace.complete(task.id)
        let end = try #require(try await phone.services.store.deliveryRequests().first { $0.mode == .known(.end) })
        for id in [task.id, end.id] {
            let row = try #require(try await phone.services.store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        let borrowed = try await reopened.createTask("继续处理语音", in: Project.defaultID)
        try await services.store.bindSession(sessionID, to: borrowed.id)
        try await services.executor.start()
        #expect(try await services.store.outcome(of: end).status == .known(.failed))
        #expect(!ext.commands.contains { $0.json["t"] as? String == "end" })
        let session = try #require(try await services.store.piSessions(sessionIDs: [sessionID])[sessionID]?.state)
        await reopened.end(session)
        let explicit = try #require(try await services.store.deliveryRequests().first { $0.mode == .known(.end) && $0.id != end.id })
        #expect(try await services.store.outcome(of: explicit).status == .known(.succeeded))
        #expect(ext.commands.contains { $0.json["t"] as? String == "end" })
        await services.executor.beginStop()()
    }
    #endif
}
