#if os(macOS)
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct VoiceStorageFlowTests {
    @Test func 跨设备保存与发出都不冒充Cue已接走() async throws {
        let cloud = ReceiptTests.WeakCloud()
        await cloud.setDown(true)
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!, store = services.store
        try await store.updateCueProfile { $0.hostID = "mac-cue"; $0.enabledAt = .now }
        services.startSync()
        services.startSpeechClock()
        let voice = VoiceFlowFixture(services)
        defer { voice.call.hangUp(); services.cancelBackgroundWork() }
        try await voice.connect()
        let request = try await voice.handoff("离线先保存，接通后交给另一台 Mac")
        #expect(voice.trip(request) == .sending)
        await cloud.setDown(false)
        await services.syncing.syncNow()
        try await eventually("服务器收下，但 Cue 尚未领取") {
            await cloud.holds(request) && voice.trip(request) == .sent
        }
        #expect(voice.stored()?.deliveredAt == nil)
        try await store.markCueMessagesDelivered([request])
        try await eventually("接走回执才显示送达") { voice.trip(request) == .delivered }
        try await voice.hangUp()
    }
}
#endif
