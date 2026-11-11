#if os(macOS)
@testable import CuePi
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

extension TaskFlowTests {
    @Test(arguments: [false, true])
    func 快慢钟与旧结果回声不能代替新结束的实际执行(automatic: Bool) async throws {
        let clock = ManualTiming(start: Date().addingTimeInterval(-60))
        let rig = TestApp(timing: clock.timing), store = rig.services.store, peer = TestApp(host: "phone")
        let services = try #require(rig.services), workspace = Workspace(services: services)
        defer { rig.pi.stop(); services.cancelBackgroundWork(); peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("旧任务", in: Project.defaultID)
        let borrower = try await workspace.createTask("新任务", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let recorder = StateRecorder(store: store, hostID: TestApp.hostID, timing: clock.timing)
        try await recorder.update(sessionID: "audit-clock", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        var session = Session(id: "audit-clock.1", sessionID: "audit-clock", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: TerminalIdentity(), state: .thinking, stateSince: .now)
        session.hosted = true
        rig.pi.attach(session, via: LostEndLink(rig.pi))
        try await workspace.complete(task.id)
        let old = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        try await services.executor.start()
        #expect(try await store.outcome(of: old).status == .known(.unconfirmed))
        let uncertain = try #require(try await store.syncRow(recordName: old.id.uuidString.lowercased()))
        #expect(try await peer.services.store.applyRemote([.save(uncertain, systemFields: Data())]).isEmpty)
        clock.advance(.seconds(1))
        try await recorder.end(sessionID: "audit-clock", confirming: [old.id])
        let ended = try #require(try await store.piSessions(sessionIDs: ["audit-clock"])["audit-clock"]?.state)
        let endedRow = try #require(try await store.syncRow(recordName: ended.id.uuidString.lowercased()))
        #expect(try await peer.services.store.applyRemote([.save(endedRow, systemFields: Data())]).isEmpty)
        #expect(try await peer.services.store.deliveryRequest(old.id)?.status == .known(.unconfirmed))
        let confirmed = try #require(try await store.syncRow(recordName: old.id.uuidString.lowercased()))
        #expect(try await peer.services.store.applyRemote([.save(confirmed, systemFields: Data())]).isEmpty)
        let peerOld = try #require(try await peer.services.store.deliveryRequest(old.id))
        #expect(peerOld.status == .known(.succeeded))
        #expect(try #require(peerOld.completedAt) > clock.now.addingTimeInterval(10))
        let success = try #require(try await peer.services.store.syncRow(recordName: old.id.uuidString.lowercased()))
        #expect(try await store.applyRemote([.save(success, systemFields: Data())]).isEmpty)
        await services.executor.beginStop()()
        clock.advance(.seconds(1))
        try await recorder.update(sessionID: "audit-clock", state: .thinking, projectID: Project.defaultID, hosted: true)
        try await store.bindSession("audit-clock", to: borrower.id)
        // 另一份尚未同步回来的未知结果，在本次领取以后才到达；明确 end 也不能扩大覆盖集合。
        let late = try await peer.services.store.requestEnd(of: ended.target, on: TestApp.hostID)
        let remoteExecutor = DeliveryExecutor(store: peer.services.store, hostID: TestApp.hostID, onIssue: { Issue.record("\($0)") }) { _, _ in
            .unconfirmed(.verbatim("结束结果丢失"))
        }
        try await remoteExecutor.start()
        #expect(try await peer.services.store.outcome(of: late).status == .known(.unconfirmed))
        await remoteExecutor.stop()
        let lateRow = try #require(try await peer.services.store.syncRow(recordName: late.id.uuidString.lowercased()))
        var handed = 0
        let live = InterleavedLink(rig.pi) { () async throws -> Void in
            handed += 1
            #expect(try await store.applyRemote([.save(lateRow, systemFields: Data())]).isEmpty)
        }
        rig.pi.attach(session, via: live)
        if automatic { try await workspace.complete(borrower.id) }
        else { await workspace.end(try #require(try await store.piSessions(sessionIDs: ["audit-clock"])["audit-clock"]?.state)) }
        let newEnd = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) && $0.id != old.id && ($0.content != "end") == automatic })
        try await services.executor.start()
        let outcome = try await store.outcome(of: newEnd)
        #expect(outcome.status == .known(.succeeded))
        #expect(rig.pi.session(sessionID: "audit-clock") == nil)
        #expect(handed == 1)
        #expect(try await store.deliveryRequest(late.id)?.status == .known(.unconfirmed))
        #expect(try await store.applyRemote([.save(success, systemFields: Data()), .save(endedRow, systemFields: Data())]).isEmpty)
        #expect(try await store.deliveryRequest(late.id)?.status == .known(.unconfirmed))
        #expect(MacDelivery.endIssue(try await store.deliveryRequests(toSession: "audit-clock"), at: services.speech)?.unconfirmedReason != nil)
        let prior = Set(try await store.deliveryRequests().map(\.id))
        await workspace.end(try #require(try await store.piSessions(sessionIDs: ["audit-clock"])["audit-clock"]?.state))
        let followup = try #require(try await store.deliveryRequests().last { $0.mode == .known(.end) && !prior.contains($0.id) })
        #expect(try await store.outcome(of: followup).status == .known(.succeeded))
        #expect(try await store.deliveryRequest(late.id)?.status == .known(.succeeded))
        await services.executor.beginStop()()
    }
}

#endif
