#if os(macOS)
@testable import CueBridge
import CueTestSupport
import CueAgent
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

final class LostEndLink: SessionLink {
    let bridge: Bridge
    init(_ bridge: Bridge) { self.bridge = bridge }
    func end(_ id: Session.ID) async throws {
        bridge.detach(id, reason: .closed(reason: "quit"))
        throw NSError(domain: "audit.lost-end-result", code: 1)
    }
}

private final class InterruptedEndLink: SessionLink {
    let bridge: Bridge
    var waiting: CheckedContinuation<Void, any Error>?
    init(_ bridge: Bridge) { self.bridge = bridge }
    func end(_ id: Session.ID) async throws {
        bridge.detach(id, reason: .closed(reason: "quit"))
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
}

final class InterleavedLink: SessionLink {
    let bridge: Bridge
    let beforeEnd: () async throws -> Void
    init(_ bridge: Bridge, beforeEnd: @escaping () async throws -> Void) { self.bridge = bridge; self.beforeEnd = beforeEnd }
    func end(_ id: Session.ID) async throws {
        try await beforeEnd()
        bridge.detach(id, reason: .closed(reason: "quit"))
    }
}

extension TaskFlowTests {
    @Test(arguments: ["source", "ui", "cue"])
    func 结束交出后执行器中断_按源端证据或明确恢复收敛(recovery: String) async throws {
        let services = try #require(rig.services), workspace = Workspace(services: services)
        defer { rig.bridge.stop(); services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续工作", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        try await StateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "audit-interrupted", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        let link = InterruptedEndLink(rig.bridge)
        let session = Session(id: "audit-interrupted.1", sessionID: "audit-interrupted", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: TerminalIdentity(), state: .thinking, stateSince: .now)
        rig.bridge.attach(session, via: link)
        try await workspace.complete(task.id)
        let automatic = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        try await services.executor.start()
        try await eventually("结束已交出") { link.waiting != nil }
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.executing))
        await services.executor.beginStop()()
        // 模拟进程在结束交出后中断：旧处理任务不能正常返回并继续确认结果。
        link.waiting?.resume(throwing: CancellationError())
        link.waiting = nil
        try await StateRecorder(store: store, hostID: TestApp.hostID).end(sessionID: "audit-interrupted", confirming: recovery == "source" ? [automatic.id] : [])
        try await services.executor.start()
        if recovery != "source" {
            #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.unconfirmed))
            await #expect(throws: CueStoreError.sessionEnding) { try await store.bindSession("audit-interrupted", to: borrower.id) }
            let ended = try #require(try await store.sessionItems(sessionIDs: ["audit-interrupted"])["audit-interrupted"]?.state)
            #expect(ended.state == .known(.ended) && !ended.canEnd)
            if recovery == "ui" {
                let issue = MacDelivery.endIssue(try await store.deliveryRequests(toSession: ended.sessionID), at: services.speech)
                #expect(issue?.unconfirmedReason != nil)
                let action = try #require(SessionActions.end(ended, ending: false, recovering: issue != nil, in: workspace))
                #expect(action.enabled)
                action.run()
                guard case .end(let asked) = workspace.sessionAsk else { Issue.record("恢复按钮必须打开结束确认框"); return }
                await workspace.end(asked)
            } else {
                let host = services.hostID
                try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
                let result = try #require(await CueTools(store: store, wait: 0).call("task", ["action": "done", "session": ended.sessionID]))
                #expect(!result.isError, "\(result.text)")
            }
            let explicit = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) && $0.content == "end" })
            #expect(try await store.outcome(of: explicit).status == .known(.succeeded))
            #expect(MacDelivery.endIssue(try await store.deliveryRequests(toSession: ended.sessionID), at: services.speech) == nil)
        }
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        #expect(try await store.sessionItems(sessionIDs: ["audit-interrupted"])["audit-interrupted"]?.state.state == .known(.ended))
        try await store.bindSession("audit-interrupted", to: borrower.id)
        #expect(try await store.card(borrower.id)?.piSessionID == "audit-interrupted")
        await services.executor.beginStop()()
    }

    @Test func 远端后到关联保留_不能撤回执行端已受理的结束() async throws {
        let services = try #require(rig.services), workspace = Workspace(services: services), peer = TestApp(host: "phone")
        defer { rig.bridge.stop(); services.cancelBackgroundWork(); peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续工作", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        try await StateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "audit-remote", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        let state = try #require(try await store.sessionItems(sessionIDs: ["audit-remote"])["audit-remote"]?.state)
        for id in [borrower.id, state.id] {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await workspace.complete(task.id)
        let automatic = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        let link = InterleavedLink(rig.bridge) { () async throws -> Void in
            #expect(try await self.store.deliveryRequest(automatic.id)?.status == .known(.executing))
            try await peer.services.store.bindSession("audit-remote", to: borrower.id)
            let row = try #require(try await peer.services.store.syncRow(recordName: borrower.id.uuidString.lowercased()))
            #expect(try await self.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
            #expect(try await self.store.card(borrower.id)?.piSessionID == "audit-remote")
        }
        let session = Session(id: "audit-remote.1", sessionID: "audit-remote", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: TerminalIdentity(), state: .thinking, stateSince: .now)
        rig.bridge.attach(session, via: link)
        try await services.executor.start()
        #expect(try await store.outcome(of: automatic).status == .known(.succeeded))
        #expect(try await store.card(borrower.id)?.piSessionID == "audit-remote")
        #expect(try await store.sessionItems(sessionIDs: ["audit-remote"])["audit-remote"]?.state.state == .known(.ended))
        await services.executor.beginStop()()
    }

    @Test(arguments: [false, true])
    func 结束结果丢失_明确结束证据跨端收敛并允许再次使用(explicitOnly: Bool) async throws {
        let clock = ManualTiming()
        let rig = TestApp(timing: clock.timing), store = rig.services.store, peer = TestApp(host: "phone")
        let services = try #require(rig.services), workspace = Workspace(services: services)
        defer { rig.bridge.stop(); services.cancelBackgroundWork(); peer.services.cancelBackgroundWork() }
        try await rig.offersPi()
        let task = try await workspace.createTask("准备发布", in: Project.defaultID)
        let borrower = try await workspace.createTask("继续工作", in: Project.defaultID)
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        let recorder = StateRecorder(store: store, hostID: TestApp.hostID)
        try await recorder.update(sessionID: "audit-lost", state: .thinking, projectID: Project.defaultID, launchToken: launch.launch?.token, hosted: true)
        try await store.deleteDelivery(launch.id)
        let session = Session(id: "audit-lost.1", sessionID: "audit-lost", agent: .pi, sessionFile: nil, pid: 1, cwd: rig.directory, terminal: TerminalIdentity(), state: .thinking, stateSince: .now)
        rig.bridge.attach(session, via: LostEndLink(rig.bridge))
        try await workspace.complete(task.id)
        let automatic = try #require(try await store.deliveryRequests().first { $0.mode == .known(.end) })
        let pending = try #require(try await store.syncRow(recordName: automatic.id.uuidString.lowercased()))
        try await services.executor.start()
        #expect(try await store.outcome(of: automatic).status == .known(.unconfirmed))
        let uncertain = try #require(try await store.syncRow(recordName: automatic.id.uuidString.lowercased()))
        #expect(try await peer.services.store.applyRemote([.save(uncertain, systemFields: Data()), .save(pending, systemFields: Data()), .save(uncertain, systemFields: Data())]).isEmpty)
        #expect(try await peer.services.store.deliveryRequest(automatic.id)?.status == .known(.unconfirmed))
        #expect(rig.bridge.session(sessionID: "audit-lost") == nil)
        var explicit: DeliveryRequest?
        if explicitOnly {
            let state = try #require(try await store.sessionItems(sessionIDs: ["audit-lost"])["audit-lost"]?.state)
            var oldEnd = try #require(try await store.syncRow(recordName: state.id.uuidString.lowercased()))
            oldEnd.fields["state"] = .text("ended")
            oldEnd.fields["stateSince"] = clock.timing.now().addingTimeInterval(-1).sqlValue
            oldEnd.fields["modifiedAt"] = .int(oldEnd.modifiedAt + 1_000)
            #expect(try await store.applyRemote([.save(oldEnd, systemFields: Data())]).isEmpty)
            #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.unconfirmed))
            await #expect(throws: CueStoreError.sessionEnding) { try await store.bindSession("audit-lost", to: borrower.id) }
            let ended = try #require(try await store.sessionItems(sessionIDs: ["audit-lost"])["audit-lost"]?.state)
            explicit = try await services.end(ended)
            #expect(try await store.outcome(of: explicit!).status == .known(.succeeded))
        } else {
            try await recorder.end(sessionID: "audit-lost", confirming: [automatic.id])
        }
        await services.executor.beginStop()()
        try await services.executor.start()
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        let ended = try #require(try await store.sessionItems(sessionIDs: ["audit-lost"])["audit-lost"]?.state)
        #expect(ended.state == .known(.ended))
        for id in [ended.id, borrower.id, automatic.id] + [explicit?.id].compactMap({ $0 }) {
            let row = try #require(try await store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await peer.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        }
        try await peer.services.store.bindSession("audit-lost", to: borrower.id)
        #expect(try await peer.services.store.card(borrower.id)?.piSessionID == "audit-lost")
        #expect(try await peer.services.store.applyRemote([.save(pending, systemFields: Data()), .save(uncertain, systemFields: Data())]).isEmpty)
        #expect(try await peer.services.store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        #expect(try await store.deliveryRequest(automatic.id)?.status == .known(.succeeded))
        try await store.bindSession("audit-lost", to: borrower.id)
        let resumed = try await rig.host.connect("audit-lost", cwd: rig.directory.path)
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
