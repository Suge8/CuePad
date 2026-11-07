#if os(macOS)
import CloudKit
@testable import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 派发期限从服务器收下起算（`DeliveryRequest.dispatchDeadline`），不从写下算：手机离线时说的话，连上才传上去，照常送到。
/// 手机与 Mac 经同一个云替身（替身同真服务器，给收下的记录盖 `creationDate`），两边从各自拿到的那条记录推出同一个锚点。
@MainActor
struct DispatchDeadlineTests {
    @Test func 手机离线十五分钟后连上_话照常送到_两端的派发期限是同一个锚点() async throws {
        let clock = ManualTiming()
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)], now: { clock.now })
        let mac = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, timing: clock.timing)
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, timing: clock.timing, host: "mac-phone")
        let atlas = try await mac.host.connect("atlas", cwd: "/work/atlas")
        mac.services.startSync()
        try await mac.services.executor.start()
        defer {
            atlas.close(bye: "quit")
            mac.pi.stop()
            for side in [mac, phone] { side.services.cancelBackgroundWork() }
        }

        // 离线（同步没起）时说的一句：一直是发送中，不到期，可以撤回
        let workspace = Workspace(services: phone.services)
        var box = ComposerDraft(text: "离线时写下的")
        let binding = Binding(get: { box }, set: { box = $0 })
        let target = SendTarget(kind: .piSession, name: "atlas", ref: "atlas")
        await workspace.speak(to: .session(target, host: TestApp.hostID, mode: .send, card: nil), from: binding) { $0.stored }.value
        let request = try #require(try await phone.services.store.deliveryRequests().first)
        clock.advance(.seconds(15 * 60))
        let offline = try #require(try await phone.services.store.deliveryRequest(request.id))
        #expect(Said.request(offline).trip(at: .always(at: clock.now)) == .sending)
        #expect(offline.isWithdrawable && offline.dispatchDeadline(local: false) == nil)

        // 连上：传上去、Mac 拉到，照常送到
        phone.services.startSync()
        let pulling = Task {
            while !Task.isCancelled {
                await phone.services.syncNow()
                await mac.services.syncNow()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { pulling.cancel() }
        try await eventually("Mac 交给 Agent") { atlas.messages.map(\.text) == ["离线时写下的"] }
        let sent = try #require(try await phone.services.store.deliveryRequest(request.id))
        let received = try #require(try await mac.services.store.deliveryRequest(request.id))
        #expect(received.status != .known(.failed))
        // 锚点：手机从上传回执、Mac 从拉到的记录各记下服务器收下的时刻，是同一个值，比写下晚了离线那十五分钟
        let anchor = try #require(sent.serverAt)
        #expect(received.serverAt == anchor)
        #expect(anchor.timeIntervalSince(request.createdAt) > 15 * 60 - 1)
        #expect(sent.dispatchDeadline(local: false) == anchor.addingTimeInterval(DeliveryRequest.phaseLimit))
        await mac.services.executor.beginStop()()
    }
}
#endif
