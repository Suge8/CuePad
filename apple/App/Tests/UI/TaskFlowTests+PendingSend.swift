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
        workspace.handOff(task.id, fresh: true)
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
        workspace.handOff(task.id, fresh: true)
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
        if action == "done" {
            // 做完的回到进行中，这个会话重新有任务在用：之后挪动它也不收
            #expect(try await store.card(task.id)?.status == .inProgress)
            try await store.moveCard(task.id, to: .top(project: Project.defaultID), after: nil)
            #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
        }
        await rig.services.executor.beginStop()()
    }

    /// 为一步开的会话随它做完结束、这一步改用了别的会话；你又对它说话把它恢复起来，它就是你自己接着用的：
    /// 之后上级被删（这一步提成顶层），或把它借给另一件事、那件做完，都不再结束它。
    @Test(arguments: ["promote", "borrow"])
    func 你恢复使用的会话_别的任务删除或完成时不结束(path: String) async throws {
        let workspace = Workspace(services: rig.services)
        try await rig.offersPi()
        let parent = try await workspace.createTask("准备发布", in: Project.defaultID)
        let step = try await store.createTask("改版本号", under: parent.id)
        let other = try await workspace.createTask("写更新说明", in: Project.defaultID)
        workspace.handOff(step.id, fresh: true)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let ext = try await rig.host.connect("restored", cwd: rig.directory.path, launchToken: launch.launch?.token)
        defer { ext.close(bye: "quit"); rig.bridge.stop(); rig.services.cancelBackgroundWork() }
        let recorder = try await rig.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        try await workspace.complete(step.id)
        // 收尾的那次结束当它已执行、请求已清理
        try await store.deleteDelivery(try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) }).id)
        try await recorder.update(sessionID: "s2", state: .settled, hosted: true)
        try await store.bindSession("s2", to: step.id)
        await workspace.speak("再改一处", to: .session(SendTarget(kind: .piSession, name: "发布", ref: ext.sessionID), host: TestApp.hostID, mode: .send, card: nil)).value
        let request = try #require(try await store.deliveryRequests().first { $0.mode == .known(.send) })
        try await rig.services.executor.start()
        try await eventually("送达") { try await store.deliveryRequest(request.id)?.status == .known(.succeeded) }
        #expect(try await store.card(step.id)?.status == .done)
        if path == "promote" {
            try await workspace.trash(parent.id)
            #expect(try await store.card(step.id)?.parentID == nil)
        } else {
            try await store.bindSession(ext.sessionID, to: other.id)
            try await workspace.complete(other.id)
        }
        #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) && $0.target.ref == ext.sessionID }.isEmpty)
        await rig.services.executor.beginStop()()
    }

    /// Mac 上"在做"读桥上的实时状态，为哪件事开、恢复过没有照库里的记录：确认框据此说完成会不会一起结束会话。
    @Test func 完成前确认_为这件事开的会话说一起结束_你恢复使用过的说不会() async throws {
        let workspace = Workspace(services: rig.services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let other = try await workspace.createTask("写更新说明", in: Project.defaultID)
        workspace.handOff(task.id, fresh: true)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let ext = try await rig.host.connect("asked", cwd: rig.directory.path, launchToken: launch.launch?.token)
        defer { ext.close(bye: "quit"); rig.bridge.stop(); rig.services.cancelBackgroundWork() }
        let recorder = try await rig.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: ext.sessionID, state: .settled, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        ext.setState(["kind": "thinking"])
        func asked(_ id: UUID) async throws -> SessionState? {
            let card = try #require(try await store.card(id))
            try await eventually("在做") { workspace.next(for: card, in: workspace.agentLinks, steps: nil)?.busySession != nil }
            try await workspace.confirmComplete(card)
            defer { workspace.sessionAsk = nil }
            guard case .complete(.agent(let busy), _, _) = workspace.sessionAsk else { return nil }
            return busy
        }
        #expect(try await asked(task.id)?.endsWithTask == true)

        try await workspace.complete(task.id)
        try await store.deleteDelivery(try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) }).id)
        try await recorder.update(sessionID: "s2", state: .settled, hosted: true)
        try await store.bindSession("s2", to: task.id)
        await workspace.speak("再改一处", to: .session(SendTarget(kind: .piSession, name: "发布", ref: ext.sessionID), host: TestApp.hostID, mode: .send, card: nil)).value
        try await store.bindSession(ext.sessionID, to: other.id)
        let borrowed = try #require(try await asked(other.id))
        #expect(borrowed.sessionID == ext.sessionID && !borrowed.endsWithTask)
    }
}
#endif
