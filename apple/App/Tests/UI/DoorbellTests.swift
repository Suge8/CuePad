#if os(macOS)
import CloudKit
@testable import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct DoorbellTests {
    @Test func 一台记下的另一台当场拉到_门铃断了重连后补按() async throws {
        let relay = try await FakeRelay()
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)])
        let still = ManualTiming()
        let phone = TestApp(sync: .built({ CloudSync(store: $0) { cloud } }, relay: relay.endpoint), timing: still.timing, host: "mac-phone")
        let mac = TestApp(sync: .built({ CloudSync(store: $0) { cloud } }, relay: relay.endpoint), timing: still.timing)
        phone.services.startSync()
        phone.services.startRelay()
        try await eventually("手机入房") { relay.joined == 1 }
        mac.services.startSync()
        mac.services.startRelay()
        try await eventually("Mac 入房") { relay.joined == 2 }

        let first = try await Workspace(services: phone.services).createCard(body: "手机上记的", in: Project.defaultID)
        try await eventually("Mac 听到门铃拉到") { try await mac.services.store.card(first.id) != nil }

        relay.drop(0, holding: true)
        try await eventually("手机知道断了") { phone.services.relay?.isLive == false }
        let rings = relay.rings
        let second = try await Workspace(services: phone.services).createCard(body: "断着时记的", in: Project.defaultID)
        try await eventually("传进 iCloud") { await cloud.saved.contains(second.id.uuidString.lowercased()) }
        #expect(try await mac.services.store.card(second.id) == nil)
        relay.release()
        try await eventually("手机连回来补按，Mac 拉到") { try await mac.services.store.card(second.id) != nil }
        #expect(relay.rings == rings + 1)
        #expect(relay.joined == 3)
    }
}
#endif
