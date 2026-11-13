#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

extension TaskFlowTests {
    @Test(arguments: ["done", "archive", "trash"], ["succeeded", "failed", "withdrawn", "remote"])
    func 在途发送释放后_已收尾任务的自建会话自动结束(action: String, outcome: String) async throws {
        let workspace = Workspace(services: rig.services)
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let ext = try await rig.host.connect("pending-send", cwd: rig.directory.path, launchToken: launch.launch?.token)
        defer { ext.close(bye: "quit"); rig.bridge.stop(); rig.services.cancelBackgroundWork() }
        let accept = ext.onCommand
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "send" { return nil }
            if command["t"] as? String == "end" { ext?.closeAfterReply(bye: "quit") }
            return ["ok": true]
        }
        let recorder = try await rig.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        let target = SendTarget(kind: .piSession, name: "发布", ref: ext.sessionID)
        await workspace.speak("核对发布", to: .session(target, host: TestApp.hostID, mode: .send, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first { $0.mode == .known(.send) })
        await workspace.speak("另一个问题", to: .session(target, host: TestApp.hostID, mode: .send, card: nil)).value
        let other = try #require(try await store.deliveryRequests().first { $0.content == "另一个问题" })
        switch action {
        case "archive": try await workspace.archive(task.id)
        case "trash": try await workspace.trash(task.id)
        default: try await workspace.complete(task.id)
        }
        #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
        workspace.remove(.request(other))
        try await eventually("撤回其中一条在途消息") { try await store.deliveryRequest(other.id) == nil }
        #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
        switch outcome {
        case "withdrawn":
            workspace.remove(.request(request))
            try await eventually("撤回最后一条在途消息") { try await store.deliveryRequest(request.id) == nil }
        case "remote":
            var row = try #require(try await store.syncRow(recordName: request.id.uuidString.lowercased()))
            row.fields["status"] = .text("succeeded")
            row.fields["modifiedAt"] = .int(row.modifiedAt + 1_000)
            #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
            #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        default:
            try await rig.services.executor.start()
            try await eventually("发送已交出，尚未收到回执") { ext.messages.count == 1 }
            let command = try #require(ext.commands.first { $0.json["t"] as? String == "send" })
            let id = try #require(command.json["id"] as? String)
            if outcome == "succeeded" { _ = accept(command.connection, command.json) }
            ext.sendRaw("{\"t\":\"ack\",\"id\":\"\(id)\",\"ok\":\(outcome == "succeeded"),\"error\":\"no_auth\"}")
            try await eventually("最后一条发送得到明确结果") { try await store.deliveryRequest(request.id)?.status == .known(outcome == "succeeded" ? .succeeded : .failed) }
        }
        let end = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) && $0.target.ref == ext.sessionID })
        try await rig.services.executor.start()
        try await eventually("任务的自建会话实际结束") { try await store.deliveryRequest(end.id)?.status == .known(.succeeded) }
        #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.count == 1)
        await rig.services.executor.beginStop()()
    }

    @Test(arguments: ["done", "archive", "trash", "project"])
    func 任务收尾后再对它的会话说话_送达后会话留着(action: String) async throws {
        let workspace = Workspace(services: rig.services)
        try await rig.offersPi()
        let project = try await store.createProject(name: "发布", color: "#000000")
        let task = try await workspace.createTask("准备发布", in: project.id)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let ext = try await rig.host.connect("resumed", cwd: rig.directory.path, launchToken: launch.launch?.token)
        defer { ext.close(bye: "quit"); rig.bridge.stop(); rig.services.cancelBackgroundWork() }
        let recorder = try await rig.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        switch action {
        case "archive": try await workspace.archive(task.id)
        case "trash": try await workspace.trash(task.id)
        case "project": try await store.trashProject(project.id)
        default: try await workspace.complete(task.id)
        }
        // 收尾的那次结束当它已执行、请求已清理；会话随后被你的话恢复起来（这里一直连着）
        let end = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        try await store.deleteDelivery(end.id)
        try await Task.sleep(for: .milliseconds(5))
        let target = SendTarget(kind: .piSession, name: "发布", ref: ext.sessionID)
        await workspace.speak("再改一处", to: .session(target, host: TestApp.hostID, mode: .send, card: nil)).value
        let request = try #require(try await store.deliveryRequests().first { $0.mode == .known(.send) })
        try await rig.services.executor.start()
        try await eventually("送达") { try await store.deliveryRequest(request.id)?.status == .known(.succeeded) }
        #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
        await rig.services.executor.beginStop()()
    }
}
#endif
