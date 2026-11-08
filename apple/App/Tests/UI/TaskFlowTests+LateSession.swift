#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

extension TaskFlowTests {
    @Test(arguments: ["done", "archive", "trash"], [false, true])
    func 任务先收尾会话后登记_复核来源与共享且不重复启动或发送(action: String, shared: Bool) async throws {
        let workspace = Workspace(services: rig.services)
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续语音", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        switch action {
        case "archive": try await workspace.archive(task.id)
        case "trash": try await workspace.trash(task.id)
        default: try await workspace.complete(task.id)
        }
        let closed = try #require(try await store.card(task.id))
        let recorder = PiStateRecorder(store: store, hostID: TestApp.hostID)
        if shared {
            try await recorder.update(sessionID: "late-session", state: .thinking, projectID: Project.defaultID, hosted: true)
            try await store.bindSession("late-session", to: borrower.id)
        }
        for state in [PiWorkState.thinking, .settled] {
            try await recorder.update(sessionID: "late-session", state: state, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        }
        let after = try #require(try await store.card(task.id))
        #expect(after.status == closed.status && after.archivedAt == closed.archivedAt && after.deletedAt == closed.deletedAt)
        #expect(try await store.piSessions(sessionIDs: ["late-session"])["late-session"]?.state.createdForTaskID == task.id)
        let requests = try await store.deliveryRequests()
        #expect(requests.filter { $0.mode == .known(.start) }.count == 1)
        #expect(requests.filter { $0.mode == .known(.send) }.isEmpty)
        #expect(requests.filter { $0.mode == .known(.end) && $0.target.ref == "late-session" }.count == (shared ? 0 : 1))
        if shared {
            #expect(try await store.card(borrower.id)?.piSessionID == "late-session")
            try await workspace.complete(borrower.id)
            #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.count == 1)
        }
    }

    @Test func 已完成任务_创建来源随云端会话晚到仍自动收尾() async throws {
        let workspace = Workspace(services: rig.services), peer = TestApp(host: "other-mac")
        defer { peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        for id in [task.id, launch.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await workspace.complete(task.id)
        try await PiStateRecorder(store: peer.services.store, hostID: "other-mac").update(
            sessionID: "cloud-late", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        let session = try #require(try await peer.services.store.piSessions(sessionIDs: ["cloud-late"])["cloud-late"]?.state)
        let row = try #require(try await peer.services.store.syncRow(recordName: session.id.uuidString.lowercased()))
        #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        let requests = try await store.deliveryRequests()
        #expect(requests.filter { $0.mode == .known(.start) }.count == 1)
        #expect(requests.filter { $0.mode == .known(.send) }.isEmpty)
        #expect(requests.filter { $0.mode == .known(.end) && $0.target.ref == "cloud-late" }.count == 1)
    }

    @Test(arguments: ["done", "archive", "trash"], [false, true])
    func 会话来源先到_手机的收尾状态分批晚到仍自动结束(action: String, delayedParent: Bool) async throws {
        let workspace = Workspace(services: rig.services), peer = TestApp(host: "other-mac")
        defer { peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let parent = try await delayedParent ? workspace.createTask("发布", in: Project.defaultID) : nil
        let task = if let parent { try await store.createTask("准备发布", under: parent.id) }
            else { try await workspace.createTask("准备发布", in: Project.defaultID) }
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        for id in [task.id, launch.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        switch action {
        case "archive": try await workspace.archive(task.id)
        case "trash": try await workspace.trash(task.id)
        default: try await workspace.complete(task.id)
        }
        try await PiStateRecorder(store: peer.services.store, hostID: "other-mac").update(
            sessionID: "source-first", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        #expect(try await peer.services.store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
        var closed = try #require(try await store.syncRow(recordName: task.id.uuidString.lowercased()))
        let acknowledged = try #require(try await peer.services.store.syncRow(recordName: task.id.uuidString.lowercased()))
        // 手机的较新任务状态获胜；这里独立于测试运行时的两次时钟采样。
        closed.fields["modifiedAt"] = .int(acknowledged.modifiedAt + 1_000)
        for _ in 0..<2 {
            #expect(try await peer.services.store.applyRemote([.save(closed, systemFields: Data())]).isEmpty)
        }
        if let parent {
            #expect(try await peer.services.store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
            let row = try #require(try await store.syncRow(recordName: parent.id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        let requests = try await peer.services.store.deliveryRequests()
        #expect(requests.filter { $0.mode == .known(.end) && $0.target.ref == "source-first" }.count == 1)
        #expect(requests.filter { $0.mode == .known(.start) }.count == 1)
        #expect(requests.filter { $0.mode == .known(.send) }.isEmpty)
    }
}
#endif
