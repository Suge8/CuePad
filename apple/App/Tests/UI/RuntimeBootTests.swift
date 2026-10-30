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

    @Test func 历史82库经83入口升级不补签Cue_真实新报告才恢复确认() async throws {
        let app = TestApp(), store = app.services.store
        _ = try await store.updateCueProfile { $0.hostID = "mac-a"; $0.enabledAt = .now }
        await Workspace(services: app.services).speak("继续检查发布", to: .cue).value
        let messages = try await store.cueMessagesToDeliver()
        try await store.markCueMessagesDelivered(messages.map(\.id))
        try await store.recordMacPresence(host: "mac-a", bootID: "before-upgrade") { true }
        try await store.setCueState(.thinking, detail: "检查发布结果")
        let location = app.services.location
        let db = RawDB(location.databaseURL)
        app.services.cancelBackgroundWork()
        try db.exec("""
            DROP TRIGGER piSessionStates_writeSeq_update;
            ALTER TABLE piSessionStates DROP COLUMN bootID;
            ALTER TABLE macPresence DROP COLUMN bootID;
            ALTER TABLE cueState DROP COLUMN hostID;
            ALTER TABLE cueState DROP COLUMN bootID;
            CREATE TRIGGER piSessionStates_writeSeq_update AFTER UPDATE OF state, stateSince, answeredAt ON piSessionStates
            WHEN old.state IS NOT new.state OR old.stateSince IS NOT new.stateSince OR old.answeredAt IS NOT new.answeredAt
            BEGIN
              UPDATE writeCounter SET seq = seq + 1;
              UPDATE piSessionStates SET writeSeq = (SELECT seq FROM writeCounter) WHERE rowid = new.rowid;
            END;
            ALTER TABLE deliveryRequests DROP COLUMN deadlineAt;
            PRAGMA user_version = 82;
            """)
        #expect(CueStore.schemaVersion(of: location.databaseURL) == 82)
        let upgraded = try CueStore(location: location)
        #expect(CueStore.schemaVersion(of: location.databaseURL) == 84 && CueStore.peerFloor == 84)
        #expect(try db.rows("SELECT hostID IS NULL, bootID IS NULL FROM cueState") == [["1", "1"]])
        let legacy = try #require(try await upgraded.cueState())
        #expect(legacy.state == .known(.thinking) && legacy.detail == "检查发布结果" && legacy.runtimeState.known == nil)
        #expect(try await upgraded.cueMessages().map(\.text) == messages.map(\.text))
        let reopened = app.relaunch()
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: reopened.store), at: .always(), local: .init(waiting: nil, here: nil))
        }
        try await reopened.store.recordMacPresence(host: "mac-a", bootID: "upgrade-boot") { true }
        let unconfirmed = try await now()
        #expect(unconfirmed.unconfirmed && unconfirmed.isLive && !unconfirmed.isBusy && !unconfirmed.hasConfirmedActivity)
        #expect(try db.rows("SELECT hostID IS NULL, bootID IS NULL FROM cueState") == [["1", "1"]])
        let recorder = PiStateRecorder(store: reopened.store, hostID: "mac-a", minInterval: .zero, bootID: "upgrade-boot")
        try await recorder.updateCue(.thinking, detail: "检查发布结果")
        let confirmed = try await now()
        #expect(confirmed.isBusy && confirmed.hasConfirmedActivity && !confirmed.unconfirmed)
        #expect(try db.rows("SELECT hostID, bootID FROM cueState") == [["mac-a", "upgrade-boot"]])
        try await recorder.updateCue(.settled)
        #expect(try await !now().isLive)
    }

}
