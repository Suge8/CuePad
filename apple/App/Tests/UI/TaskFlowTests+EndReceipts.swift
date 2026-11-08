#if os(macOS)
@testable import CuePi
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

private final class LostEndLink: SessionLink {
    let bridge: PiBridge
    init(_ bridge: PiBridge) { self.bridge = bridge }
    func end(_ id: PiSession.ID) async throws {
        bridge.detach(id, reason: .closed(reason: "quit"))
        throw NSError(domain: "audit.lost-end-result", code: 1)
    }
}

private final class InterruptedEndLink: SessionLink {
    let bridge: PiBridge
    var waiting: CheckedContinuation<Void, Never>?
    init(_ bridge: PiBridge) { self.bridge = bridge }
    func end(_ id: PiSession.ID) async throws {
        bridge.detach(id, reason: .closed(reason: "quit"))
        await withCheckedContinuation { waiting = $0 }
    }
}

private final class InterleavedLink: SessionLink {
    let bridge: PiBridge
    let beforeEnd: () async throws -> Void
    init(_ bridge: PiBridge, beforeEnd: @escaping () async throws -> Void) { self.bridge = bridge; self.beforeEnd = beforeEnd }
    func end(_ id: PiSession.ID) async throws {
        try await beforeEnd()
        bridge.detach(id, reason: .closed(reason: "quit"))
    }
}

extension TaskFlowTests {
    @Test func 结束交出后执行器中断_正证据使旧请求成功() async throws {
        let services = try #require(rig.services), workspace = Workspace(services: services)
        defer { rig.pi.stop(); services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续工作", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "audit-interrupted", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        let link = InterruptedEndLink(rig.pi)
        var session = PiSession(id: "audit-interrupted.1", sessionID: "audit-interrupted", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: PiTerminal(), state: .thinking, stateSince: .now)
        session.hosted = true
        rig.pi.attach(session, via: link)
        try await workspace.complete(task.id)
        let automatic = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        try await services.executor.start()
        try await eventually("结束已交出") { link.waiting != nil }
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.executing))
        await services.executor.beginStop()()
        link.waiting?.resume()
        link.waiting = nil
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).end(sessionID: "audit-interrupted")
        try await services.executor.start()
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        #expect(try await store.piSessions(sessionIDs: ["audit-interrupted"])["audit-interrupted"]?.state.state == .known(.ended))
        try await store.bindSession("audit-interrupted", to: borrower.id)
        #expect(try await store.card(borrower.id)?.piSessionID == "audit-interrupted")
        await services.executor.beginStop()()
    }

    @Test func 远端后到关联保留_不能撤回执行端已受理的结束() async throws {
        let services = try #require(rig.services), workspace = Workspace(services: services), peer = TestApp(host: "phone")
        defer { rig.pi.stop(); services.cancelBackgroundWork(); peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续工作", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "audit-remote", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        let state = try #require(try await store.piSessions(sessionIDs: ["audit-remote"])["audit-remote"]?.state)
        for id in [borrower.id, state.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await workspace.complete(task.id)
        let automatic = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        let link = InterleavedLink(rig.pi) { () async throws -> Void in
            #expect(try await self.store.deliveryRequest(automatic.id)?.status == .known(.executing))
            try await peer.services.store.bindSession("audit-remote", to: borrower.id)
            let row = try #require(try await peer.services.store.syncRow(recordName: borrower.id.uuidString.lowercased()))
            #expect(try await self.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
            #expect(try await self.store.card(borrower.id)?.piSessionID == "audit-remote")
        }
        var session = PiSession(id: "audit-remote.1", sessionID: "audit-remote", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: PiTerminal(), state: .thinking, stateSince: .now)
        session.hosted = true
        rig.pi.attach(session, via: link)
        try await services.executor.start()
        #expect(try await store.outcome(of: automatic).status == .known(.succeeded))
        #expect(try await store.card(borrower.id)?.piSessionID == "audit-remote")
        #expect(try await store.piSessions(sessionIDs: ["audit-remote"])["audit-remote"]?.state.state == .known(.ended))
        await services.executor.beginStop()()
    }

    @Test(arguments: [false, true])
    func 结束结果丢失_明确结束证据跨端收敛并允许再次使用(explicitOnly: Bool) async throws {
        let clock = ManualTiming()
        let rig = TestApp(timing: clock.timing), store = rig.services.store, peer = TestApp(host: "phone")
        let services = try #require(rig.services), workspace = Workspace(services: services)
        defer { rig.pi.stop(); services.cancelBackgroundWork(); peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续工作", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let recorder = PiStateRecorder(store: store, hostID: TestApp.hostID)
        try await recorder.update(sessionID: "audit-lost", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        var session = PiSession(id: "audit-lost.1", sessionID: "audit-lost", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: PiTerminal(), state: .thinking, stateSince: .now)
        session.hosted = true
        rig.pi.attach(session, via: LostEndLink(rig.pi))
        try await workspace.complete(task.id)
        let automatic = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        let pending = try #require(try await store.syncRow(recordName: automatic.id.uuidString.lowercased()))
        try await services.executor.start()
        #expect(try await store.outcome(of: automatic).status == .known(.unconfirmed))
        let uncertain = try #require(try await store.syncRow(recordName: automatic.id.uuidString.lowercased()))
        #expect(try await peer.services.store.applyRemote([.save(uncertain, systemFields: Data()), .save(pending, systemFields: Data()), .save(uncertain, systemFields: Data())]).isEmpty)
        #expect(try await peer.services.store.deliveryRequest(automatic.id)?.status == .known(.unconfirmed))
        #expect(rig.pi.session(sessionID: "audit-lost") == nil)
        var explicit: DeliveryRequest?
        if explicitOnly {
            let state = try #require(try await store.piSessions(sessionIDs: ["audit-lost"])["audit-lost"]?.state)
            var oldEnd = try #require(try await store.syncRow(recordName: state.id.uuidString.lowercased()))
            oldEnd.fields["state"] = .text("ended")
            oldEnd.fields["stateSince"] = clock.timing.now().addingTimeInterval(-1).sqlValue
            oldEnd.fields["modifiedAt"] = .int(oldEnd.modifiedAt + 1_000)
            #expect(try await store.applyRemote([.save(oldEnd, systemFields: Data())]).isEmpty)
            #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.unconfirmed))
            await #expect(throws: CueStoreError.sessionEnding) { try await store.bindSession("audit-lost", to: borrower.id) }
            let ended = try #require(try await store.piSessions(sessionIDs: ["audit-lost"])["audit-lost"]?.state)
            explicit = try await services.end(ended)
            #expect(try await store.outcome(of: explicit!).status == .known(.succeeded))
        } else {
            try await recorder.end(sessionID: "audit-lost")
        }
        await services.executor.beginStop()()
        try await services.executor.start()
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        let ended = try #require(try await store.piSessions(sessionIDs: ["audit-lost"])["audit-lost"]?.state)
        #expect(ended.state == .known(.ended))
        for id in [ended.id, borrower.id] + [explicit?.id].compactMap({ $0 }) {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await peer.services.store.bindSession("audit-lost", to: borrower.id)
        #expect(try await peer.services.store.card(borrower.id)?.piSessionID == "audit-lost")
        #expect(try await peer.services.store.applyRemote([.save(pending, systemFields: Data()), .save(uncertain, systemFields: Data())]).isEmpty)
        #expect(try await peer.services.store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        try await store.bindSession("audit-lost", to: borrower.id)
        let resumed = try await rig.host.connect("audit-lost", cwd: rig.directory.path, hosted: true)
        defer { resumed.close(bye: "quit") }
        await workspace.speak("继续处理", to: .session(SendTarget(kind: .piSession, name: "会话", ref: "audit-lost"), host: TestApp.hostID, mode: .send, card: borrower.id)).value
        #expect(workspace.notice?.isError != true)
        let sent = try #require(try await store.deliveryRequests().first { $0.mode == .known(.send) })
        #expect(try await store.outcome(of: sent).status == .known(.succeeded))
        #expect(resumed.messages.map(\.text) == ["继续处理"])
        await services.executor.beginStop()()
    }
}
#endif
