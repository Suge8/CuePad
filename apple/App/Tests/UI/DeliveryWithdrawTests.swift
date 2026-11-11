#if os(macOS)
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge

@MainActor
@Suite(.releasesLibraries)
struct DeliveryWithdrawTests {
    @Test func 手机上的话已到服务器Mac还没领取_移除由Mac核对后撤回_会话没收到() async throws {
        let clock = ManualTiming()
        let mac = TestApp(timing: clock.timing), phone = TestApp(timing: clock.timing, host: "phone")
        let ext = try await mac.host.connect("withdraw-target", cwd: mac.directory.path)
        defer { ext.crash(); mac.bridge.stop(); mac.services.cancelBackgroundWork(); phone.services.cancelBackgroundWork() }
        try await mac.runtimeRecorder(on: TestApp.hostID).update(sessionID: ext.sessionID, state: .settled)
        let target = try #require(try await mac.services.store.allSessionStates().first { $0.sessionID == ext.sessionID })
        let workspace = Workspace(services: phone.services), phoneStore = phone.services.store, macStore = mac.services.store

        let request = try await workspace.said(ComposerDraft(text: "发错了"), to: target, mode: .send)
        let row = try #require(try await phoneStore.syncRow(recordName: request.id.uuidString.lowercased()))
        try await phoneStore.markPushed([(row, Data(), clock.now)])
        #expect(try await macStore.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        let sent = try #require(try await phoneStore.deliveryRequest(request.id))
        #expect(sent.status == .known(.pending) && sent.reachedServer)

        workspace.remove(.request(sent))
        let withdrawal = try #require(try await eventually(phoneStore, { try $0.deliveryRequests().first { $0.mode == .known(.withdraw) } }) { $0 != nil })
        #expect(try await phoneStore.deliveryRequest(request.id) != nil, "Mac 没核对过，手机不能自己删")
        let asked = try #require(try await phoneStore.syncRow(recordName: withdrawal.id.uuidString.lowercased()))
        #expect(try await macStore.applyRemote([.save(asked, systemFields: Data())]).isEmpty)
        try await mac.services.executor.start()
        #expect(try await macStore.outcome(of: withdrawal).status == .known(.succeeded))
        #expect(try await macStore.deliveryRequest(request.id) == nil)

        let receipt = try #require(try await macStore.syncRow(recordName: asked.id))
        #expect(try await phoneStore.applyRemote([.save(receipt, systemFields: Data())]).isEmpty)
        try await eventually("Mac 核对没交出后手机才移除") { try await phoneStore.deliveryRequest(request.id) == nil }
        #expect(workspace.notice?.isError != true)
        #expect(ext.messages.isEmpty)
        await mac.services.executor.beginStop()()
    }
}
#endif
