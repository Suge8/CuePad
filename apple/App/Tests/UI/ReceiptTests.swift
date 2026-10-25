import CloudKit
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 说出去的话到哪了只看这句自己：服务器收下了是已发出、Mac 回执了是已送达，写下满时限还没出这台、或已发出满时限没回执是没能送达
/// （`Speech`，App 一处刷新"此刻"，`SpeechClock`）。全局同步状态一时不通不让已发出的话变红。
/// 时间用手动推进的钟：到点翻状态靠 App 自己的那一次睡眠，不靠测试去重读。会话在 mac-b、Cue 运行在 mac-cue，都要经同步。
@MainActor
struct ReceiptTests {
    let clock = ManualTiming()

    /// 真实的同步代码连内存里的 iCloud 替身，能整个断开（拉取、上传都报网络失败），能替 mac-b 写回结果。
    actor WeakCloud: SyncCloud {
        let inner: SimulatedCloud
        var down = false

        init() {
            let floor = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
            floor[PeerFloor.field] = CueStore.supportedSchemaVersions.lowerBound as NSNumber
            inner = SimulatedCloud([floor])
        }

        func setDown(_ down: Bool) { self.down = down }
        func holds(_ id: UUID) async -> Bool { await inner.saved.contains(id.uuidString.lowercased()) }

        /// mac-b 领取并执行了这条请求，结果写回服务器。
        func macAnswers(_ id: UUID) async throws {
            let record = try #require(await inner.records([CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: CloudSync.zoneID)]).first)
            let done = try #require(record.copy() as? CKRecord)
            let now = Int64(Date.now.timeIntervalSince1970 * 1000) + 1
            done["status"] = DeliveryStatus.succeeded.rawValue as NSString
            done["handledBy"] = "mac-b" as NSString
            done["completedAt"] = now as NSNumber
            done["modifiedAt"] = now as NSNumber
            await inner.put(done)
        }

        private func reachable() throws { if down { throw CKError(.networkFailure) } }

        func accountStatus() async throws -> CKAccountStatus { await inner.accountStatus() }
        func accountName() async throws -> String { await inner.accountName() }
        func relaySecret() async throws -> Data { await inner.relaySecret() }
        func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
            try reachable()
            return await inner.changes(since: token, keys: keys)
        }
        func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
            try reachable()
            return await inner.records(ids)
        }
        func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
            try reachable()
            return await inner.upload(saving: saving, deleting: deleting)
        }
        func saveZone() async throws { try reachable() }
        func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
        func save(_ subscription: CKSubscription) async throws {}
        func delete(_ id: CKSubscription.ID) async throws {}
    }

    private func session(in store: CueStore) async throws -> PiSessionState {
        let recorder = PiStateRecorder(store: store, hostID: "mac-b")
        try await recorder.update(sessionID: "atlas", state: .thinking, title: "atlas")
        try await recorder.update(sessionID: "atlas", state: .settled)
        return try #require(try await store.allPiSessionStates().first { $0.sessionID == "atlas" })
    }

    private func enableCue(in store: CueStore) async throws {
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
    }

    private func sayToCue(_ workspace: Workspace, _ text: String) async throws -> CueMessage {
        workspace.cue.draft = ComposerDraft(text: text)
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: workspace.services.store.files) }?.value
        return try #require(try await workspace.services.store.cueMessages().last { $0.author == .known(.you) })
    }

    private func sayToSession(_ workspace: Workspace, _ target: PiSessionState, _ text: String) async throws -> DeliveryRequest {
        let services = workspace.services
        let box = services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: text)
        await workspace.speak(to: .session(target, mode: .send), from: box) { try $0.stored(in: services.store.files) }?.value
        return try #require(try await services.store.deliveryRequests().first)
    }

    /// 把钟拨到 `target`（记录的时刻是真实时间，钟从测试开始时起走，所以按时刻拨，不按秒数）：等 App 的那一次睡眠睡下再拨。
    private func advance(to target: Date) async {
        await clock.waitForSleeper()
        clock.advance(.seconds(target.timeIntervalSince(clock.now)))
    }

    private func row(_ services: AppServices) -> PiShown? {
        services.liveSessions.live.first { $0.state.sessionID == "atlas" }.map(Workspace(services: services).shown)
    }

    /// 这句此刻到哪了：记录（连同服务器收下过没有）从库里读，配上 App 的"此刻"。
    private func trip(of request: DeliveryRequest, _ services: AppServices) async throws -> Speech.Trip {
        Said.request(try #require(try await services.store.deliveryRequest(request.id))).trip(at: services.speech)
    }

    private func trip(of message: CueMessage, _ services: AppServices) async throws -> Speech.Trip {
        let current = try #require(try await services.store.cueMessages().first { $0.id == message.id })
        return Said.cue(current, host: "mac-cue").trip(at: services.speech)
    }

    private func presence(_ services: AppServices) async throws -> CuePresence {
        CuePresence.derive(try await CueDigest.read(from: services.store), at: services.speech)
    }

    /// 话传上服务器就是已发出（会话行、Cue 页头同一个说法），不等 Mac 回执。弱网：一次拉取失败、同步状态成了连不上 iCloud，
    /// 已发出的话不变红；断着时写下的话是发送中，满 `Speech.sendLimit` 才没能送达（只这一句，写同步的原因）。恢复后它传上去回到已发出；
    /// Mac 回执的那句已送达，另一句已发出后满 `Speech.receiptLimit` 没回执是 Mac 迟迟没收下。
    @Test
    func 说的话到服务器是已发出_回执是已送达_一次失败不让别的话变红_没发出与没回执各自到点() async throws {
        let cloud = WeakCloud()
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, timing: clock.timing)
        let services = app.services!
        let store = services.store
        try await enableCue(in: store)
        let target = try await session(in: store)
        services.startSync()
        services.startSpeechClock()
        services.startLiveSessions()
        defer { services.cancelBackgroundWork() }
        try await eventually("同步通了") { services.syncStatus == .idle && services.syncReconciled }
        let workspace = Workspace(services: services)

        let first = try await sayToSession(workspace, target, "改完再跑一遍")
        let toCue = try await sayToCue(workspace, "顺便看看登录回调")
        try await eventually("服务器收下") {
            let held = [await cloud.holds(first.id), await cloud.holds(toCue.id)]
            return held == [true, true]
        }
        try await eventually("已发出") { [try await trip(of: first, services), try await trip(of: toCue, services)] == [.sent, .sent] }
        try await eventually("会话行是已发出") { row(services)?.label == "已发出" }
        #expect(try await presence(services) == .sending(.sent))

        // 弱网：一次拉取失败，同步状态连不上 iCloud；已发出的照旧
        await cloud.setDown(true)
        await services.syncNow()
        try await eventually("连不上 iCloud") { services.syncStatus == .offline }
        #expect(try await trip(of: first, services) == .sent)
        #expect(try await trip(of: toCue, services) == .sent)
        #expect(row(services)?.label == "已发出")

        // 断着时写下的一句：传不出去，时限内仍是发送中，满时限只它没能送达
        let second = try await sayToSession(workspace, target, "再看看日志")
        #expect(try await trip(of: second, services) == .sending)
        await advance(to: second.createdAt.addingTimeInterval(Speech.sendLimit - 1))
        #expect(try await trip(of: second, services) == .sending)
        await advance(to: second.createdAt.addingTimeInterval(Speech.sendLimit))
        try await eventually("满时限没发出") { try await trip(of: second, services) == .failed(.unsent) }
        #expect(Speech.Failure.unsent.text(sync: services.syncStatus) == "连不上 iCloud，发不到 Mac")
        #expect(try await trip(of: first, services) == .sent)
        #expect(try await trip(of: toCue, services) == .sent)
        try await eventually("会话行是没能送达，只数这一句") { row(services)?.undelivered == .unsent && services.liveSessions.undelivered["atlas"] == 1 }

        // 恢复：没发出的那句传上去，回到已发出；Mac 回执了第一句，它已送达
        await cloud.setDown(false)
        await services.syncNow()
        try await eventually("恢复后传上去") { try await trip(of: second, services) == .sent }
        try await cloud.macAnswers(first.id)
        await services.syncNow()
        try await eventually("回执回来") { try await trip(of: first, services) == .delivered }
        try await eventually("会话行回到已发出，不再数没送到") { row(services)?.label == "已发出" && services.liveSessions.undelivered["atlas"] == nil }

        // 第二句已发出，同步通着满时限（从恢复那一刻算）没回执：Mac 迟迟没收下
        let recovered = try #require(services.speech.reachableSince)
        await advance(to: recovered.addingTimeInterval(Speech.receiptLimit - 1))
        #expect(try await trip(of: second, services) == .sent)
        await advance(to: recovered.addingTimeInterval(Speech.receiptLimit))
        try await eventually("满时限没回执") { try await trip(of: second, services) == .failed(.timedOut) }
        try await eventually("会话行翻成没能送达") { row(services)?.undelivered == .timedOut && services.liveSessions.undelivered["atlas"] == 1 }
        #expect(row(services)?.label == "没能送达")
    }

    /// 断网时说的话（对 Cue、对会话）先是发送中，满时限还没出这台才没能送达，不说 Mac 迟迟没收下、不说 Cue 在睡觉。断网超过手机主动拉取的
    /// 两分钟窗口后恢复：立即同步一次（交回引擎的记录当场传出、回执当场拉回），主动拉取重开一个窗口；没发出的话回到发送中，时限从恢复那一刻重新算。
    /// 传出与回执经同步走完一圈见 CueSync 的 DeviceFlowTests（断网写下的请求恢复后到 Mac、结果回到手机）。
    @Test
    func 断网时说的话_满时限才没能送达不报没回应_恢复后立即同步并重开拉取_时限重算() async throws {
        let app = TestApp(timing: clock.timing)
        let services = app.services!
        let store = services.store
        func setSync(_ status: SyncStatus) async throws {
            app.sync.emit(SyncState(status: status, issues: []))
            try await eventually("同步状态 \(status)") { services.syncStatus == status }
        }
        try await enableCue(in: store)
        try await store.recordMacPresence(host: "mac-cue") { false }  // 断网前同步来的：那台已睡（断网时本机说不准，不说它在睡觉）
        let target = try await session(in: store)
        services.startSync()
        services.startSpeechClock()
        services.startLiveSessions()
        try await setSync(.idle)
        services.startPolling()
        let workspace = Workspace(services: services)

        try await setSync(.offline)
        try await eventually("断网") { services.speech.reachableSince == nil }
        let toCue = try await sayToCue(workspace, "顺便看看登录回调")
        let toSession = try await sayToSession(workspace, target, "改完再跑一遍")
        func trips() async throws -> [Speech.Trip] { [try await trip(of: toCue, services), try await trip(of: toSession, services)] }

        #expect(try await trips() == [.sending, .sending])
        try await eventually("会话行是发送中") { row(services)?.status == .delivery(.inTransit(.sending)) }

        // 断网两分钟多：拉取的窗口走完（手机）；没发出的两句到点没能送达
        try await eventually("在等回执时按节奏拉") { app.sync.syncNows > 0 }
        await clock.waitForSleeper()
        clock.advance(.seconds(121))
        #if os(iOS)
        try await eventually("拉取窗口走完") { clock.sleeperCount == 0 }  // 醒来时已过两分钟，不再拉
        #else
        try await eventually("拉取醒来又睡下") { app.sync.syncNows > 1 && clock.sleeperCount > 0 }  // Mac 在等就一直拉
        #endif
        #expect(try await trips() == [.failed(.unsent), .failed(.unsent)])
        try await eventually("会话行是没能送达") { row(services)?.undelivered == .unsent }
        #expect(services.liveSessions.undelivered["atlas"] == 1)
        #expect(try await presence(services) != .asleep)
        let syncs = app.sync.syncNows

        try await store.recordMacPresence(host: "mac-cue") { true }  // Cue 那台其实醒着（断网时没同步来）
        try await setSync(.idle)
        try await eventually("恢复") { services.speech.reachableSince != nil }
        // 钟没动：恢复时立即同步的那一拉也是新窗口的开头，之后按节奏的拉取睡在新窗口的第一个间隔里，不另拉
        try await eventually("恢复时立即同步，拉取重新开始") { app.sync.syncNows == syncs + 1 && clock.sleeperCount > 0 }
        #expect(try await trips() == [.sending, .sending])
        try await eventually("会话行回到发送中") { row(services)?.status == .delivery(.inTransit(.sending)) }
        #expect(services.liveSessions.undelivered["atlas"] == nil)

        // 写下已远过时限，但恢复才差一秒到：还在发送中
        clock.advance(.seconds(Speech.sendLimit - 1))
        #expect(try await trips() == [.sending, .sending])
        #expect(try await presence(services) == .sending(.sending))
    }
}
