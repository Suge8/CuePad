@testable import CueStore
import Foundation
import Testing
@testable import CuePad

/// #43：旧 boot 或旧宿主晚到的 Cue 报告不能重新变成当前运行证明。
struct RuntimeBootTests {
    @Test func Cue旧报告晚到与换Mac不复活忙碌_新报告与同boot重开保持确认() async throws {
        let source = TestApp(), receiver = TestApp()
        let sourceStore = source.services.store, store = receiver.services.store
        _ = try await sourceStore.updateCueProfile { $0.hostID = "mac-a"; $0.enabledAt = .now }
        let original = try await source.runtimeRecorder(on: "mac-a", boot: "old-boot")
        await Workspace(services: source.services).speak("检查发布结果", to: .cue).value
        try await sourceStore.markCueMessagesDelivered(try await sourceStore.cueMessagesToDeliver().map(\.id))
        try await original.updateCue(.thinking)
        var old = try #require(try await sourceStore.syncRow(recordName: CueState.recordID.uuidString.lowercased()))
        _ = try await store.updateCueProfile { $0.hostID = "mac-a"; $0.enabledAt = .now }
        try await store.recordMacPresence(host: "mac-a", bootID: "new-boot") { true }
        #expect(try await store.applyRemote([.save(old, systemFields: Data())]).isEmpty)
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(), local: .init(waiting: nil, here: nil))
        }
        let stale = try await now()
        #expect(!stale.isBusy && stale.unconfirmed && stale.isLive && !stale.hasConfirmedActivity)
        #expect(try await store.cueState()?.state == .known(.thinking))
        let current = PiStateRecorder(store: store, hostID: "mac-a", minInterval: .zero, bootID: "new-boot")
        try await current.updateCue(.thinking)
        #expect(try await now().isBusy)
        let reopened = receiver.relaunch()
        let sameBoot = CueNow(try await CueDigest.read(from: reopened.store), at: .always(), local: .init(waiting: nil, here: nil))
        #expect(sameBoot.isBusy && sameBoot.hasConfirmedActivity)
        old.fields["modifiedAt"] = .int(Int64(Date.now.addingTimeInterval(10).timeIntervalSince1970 * 1000))
        #expect(try await store.applyRemote([.save(old, systemFields: Data())]).isEmpty)
        let late = try await now()
        #expect(!late.isBusy && late.unconfirmed)
        try await current.updateCue(.tool, detail: "read · release.log")
        #expect(try await now().isBusy)
        _ = try await store.updateCueProfile { $0.hostID = "mac-b" }
        try await store.recordMacPresence(host: "mac-b", bootID: "boot-b") { true }
        let moved = try await now()
        #expect(!moved.isBusy && moved.isLive && !moved.hasConfirmedActivity)
        let replacement = PiStateRecorder(store: store, hostID: "mac-b", minInterval: .zero, bootID: "boot-b")
        try await replacement.updateCue(.thinking)
        #expect(try await now().isBusy)
        try await replacement.updateCue(.settled)
        #expect(try await !now().isLive)
    }
}
