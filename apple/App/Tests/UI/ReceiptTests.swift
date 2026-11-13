import CloudKit
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 时间用手动推进的钟：到点翻状态靠 App 自己的那一次睡眠，不靠测试去重读。会话在 mac-b、Cue 运行在 mac-cue，都要经同步。
@MainActor
@Suite(.releasesLibraries)
struct ReceiptTests {
    let clock = ManualTiming()

    /// 真实的同步代码连内存里的 iCloud 替身，能整个断开（拉取、上传都报网络失败），能替 mac-b 写回结果。
    actor WeakCloud: SyncCloud {
        let inner: SimulatedCloud
        var down = false

        init(now: @escaping @Sendable () -> Date = Date.init) {
            inner = SimulatedCloud([.peerFloor(CueStore.peerFloor)], now: now)
        }

        func setDown(_ down: Bool) { self.down = down }
        func holds(_ id: UUID) async -> Bool { await inner.saved.contains(id.uuidString.lowercased()) }

        func macAnswers(_ id: UUID, status: String = DeliveryStatus.succeeded.rawValue) async throws {
            let record = try #require(await inner.records([CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: CloudSync.zoneID)]).first)
            let done = try #require(record.copy() as? CKRecord)
            let now = Int64(Date.now.timeIntervalSince1970 * 1000) + 1
            done["status"] = status as NSString
            done["handledBy"] = "mac-b" as NSString
            done["completedAt"] = now as NSNumber
            done["modifiedAt"] = now as NSNumber
            await inner.put(done)
        }

        private func reachable() throws { if down { throw CKError(.networkFailure) } }

        func accountStatus() async throws -> CKAccountStatus { await inner.accountStatus() }
        func accountName() async throws -> String { await inner.accountName() }
        func relaySecret() async throws -> Data { await inner.relaySecret() }
        func diagnosticChanges(since token: Data?) async throws -> ZoneChangeBatch { try await inner.diagnosticChanges(since: token) }
        func uploadDiagnostics(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
          await inner.uploadDiagnostics(saving: saving, deleting: deleting)
        }
        func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
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
        func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
            try reachable()
            return await inner.uploadFile(record, progress: progress)
        }
        func resumedFileUploads() async throws -> [ResumedUpload] { [] }
        func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord? {
            try reachable()
            return await inner.downloadFile(id, progress: progress)
        }
        func saveZone() async throws { try reachable() }
        func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { [:] }
        func save(_ subscription: CKSubscription) async throws {}
        func delete(_ id: CKSubscription.ID) async throws {}
    }

    private func session(in store: CueStore) async throws -> SessionState {
        let recorder = StateRecorder(store: store, hostID: "mac-b")
        try await recorder.update(sessionID: "atlas", state: .thinking, title: "atlas")
        try await recorder.update(sessionID: "atlas", state: .settled)
        return try #require(try await store.allSessionStates().first { $0.sessionID == "atlas" })
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
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { $0.stored }.value
        return try #require(try await workspace.services.store.cueMessages().last { $0.author == .known(.you) })
    }

    private func sayToSession(_ workspace: Workspace, _ target: SessionState, _ text: String) async throws -> DeliveryRequest {
        let services = workspace.services
        let box = services.settings.replyDraftBinding(for: target.id)
        box.wrappedValue = ComposerDraft(text: text)
        await workspace.speak(to: .session(target, mode: .send), from: box) { $0.stored }.value
        return try #require(try await services.store.deliveryRequests().first)
    }

    /// 把钟拨到 `target`（记录的时刻是真实时间，钟从测试开始时起走，所以按时刻拨，不按秒数）：等 App 的那一次睡眠睡下再拨。
    private func advance(to target: Date) async throws {
        try await clock.waitForSleeper()
        clock.advance(.seconds(target.timeIntervalSince(clock.now)))
    }

    private func row(_ services: AppServices) -> SessionShown? {
        services.liveSessions.live.first { $0.state.sessionID == "atlas" }.map(Workspace(services: services).shown)
    }

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

    @Test
    func 那台Mac已知没开_这句不写下字留在输入框_同步断着说不准时照常排着() async throws {
        let cloud = WeakCloud { [clock] in clock.now }
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, timing: clock.timing)
        let services = app.services!
        let store = services.store
        let target = try await session(in: store)
        try await store.recordMacPresence(host: "mac-b") { false }
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("同步通了") { services.syncing.state.status == .idle && services.syncing.state.reconciled }
        let workspace = Workspace(services: services)
        let box = services.settings.replyDraftBinding(for: target.id)

        box.wrappedValue = ComposerDraft(text: "改完再跑一遍")
        await workspace.speak(to: .session(target, mode: .send), from: box) { $0.stored }.value
        #expect(workspace.notice?.isError == true)
        #expect(box.wrappedValue.text == "改完再跑一遍")
        #expect(try await store.deliveryRequests().isEmpty)

        await cloud.setDown(true)
        await services.syncing.syncNow()
        try await eventually("连不上 iCloud") { services.syncing.state.status == .offline }
        await workspace.speak(to: .session(target, mode: .send), from: box) { $0.stored }.value
        #expect(try await store.deliveryRequests().map(\.content) == ["改完再跑一遍"])
        #expect(box.wrappedValue.text.isEmpty)
    }

    @Test
    func 说的话到服务器是已发出_回执是已送达_一次失败不让别的话变红_断着时排着不到点_没回执到点() async throws {
        let cloud = WeakCloud { [clock] in clock.now }
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, timing: clock.timing)
        let services = app.services!
        let store = services.store
        try await enableCue(in: store)
        let target = try await session(in: store)
        services.startSync()
        services.startSpeechClock()
        services.startLiveSessions()
        defer { services.cancelBackgroundWork() }
        try await eventually("同步通了") { services.syncing.state.status == .idle && services.syncing.state.reconciled }
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

        // 手机还只看到 pending，Mac 也可能已经领取：上传过的旧快照不能靠删除来授权重发。
        await workspace.resend(.request(first), restoringInto: services.settings.replyDraftBinding(for: target.id)).value
        #expect(workspace.notice?.isError == true)
        #expect(try await store.deliveryRequests(toSession: target.sessionID).map(\.id) == [first.id])

        await cloud.setDown(true)
        await services.syncing.syncNow()
        try await eventually("连不上 iCloud") { services.syncing.state.status == .offline }
        #expect(try await trip(of: first, services) == .sent)
        #expect(try await trip(of: toCue, services) == .sent)
        #expect(row(services)?.label == "已发出")

        let second = try await sayToSession(workspace, target, "再看看日志")
        #expect(try await trip(of: second, services) == .sending)
        try await advance(to: second.createdAt.addingTimeInterval(Speech.sendLimit + 1))
        #expect(try await trip(of: second, services) == .sending)
        #expect(try await trip(of: first, services) == .sent)
        #expect(try await trip(of: toCue, services) == .sent)
        #expect(row(services)?.undelivered == nil && services.liveSessions.undelivered["atlas"] == nil)

        await cloud.setDown(false)
        await services.syncing.syncNow()
        try await eventually("恢复后传上去") { try await trip(of: second, services) == .sent }
        try await cloud.macAnswers(first.id)
        await services.syncing.syncNow()
        try await eventually("回执回来") { try await trip(of: first, services) == .delivered }
        try await eventually("会话行回到已发出，不再数没送到") { row(services)?.label == "已发出" && services.liveSessions.undelivered["atlas"] == nil }

        // 派发期限从服务器收下起算（恢复后传上去的那一刻），不从断网时写下算
        let expires = try #require(try await store.deliveryRequest(second.id)?.dispatchDeadline).addingTimeInterval(Speech.receiptLimit)
        try await advance(to: expires.addingTimeInterval(-1))
        #expect(try await trip(of: second, services) == .sent)
        try await advance(to: expires)
        try await eventually("到期按未确认") { try await trip(of: second, services).unconfirmedReason != nil }
        #expect(row(services)?.isRunning == false)
        #expect(Speech.undelivered(try await store.deliveryRequests(), at: services.speech) == 0)
        try await cloud.macAnswers(second.id)
        await services.syncing.syncNow()
        try await eventually("迟到的原回执收敛") { try await trip(of: second, services) == .delivered }
    }

    @Test
    func 断网时说的话_排着不判没能送达_恢复后立即同步并重开拉取_时限从恢复起算() async throws {
        let app = TestApp(timing: clock.timing)
        let services = app.services!
        let store = services.store
        defer { services.cancelBackgroundWork() }
        func setSync(_ status: SyncStatus) async throws {
            app.sync.emit(SyncState(status: status, issues: []))
            try await eventually("同步状态 \(status)") { services.syncing.state.status == status }
        }
        try await enableCue(in: store)
        try await store.recordMacPresence(host: "mac-cue") { false }  // 断网前同步来的：那台已睡（断网时本机说不准，不说它在睡觉）
        let target = try await session(in: store)
        services.startSync()
        services.startSpeechClock()
        services.startLiveSessions()
        try await setSync(.idle)
        services.syncing.startPolling()
        let workspace = Workspace(services: services)

        try await setSync(.offline)
        try await eventually("断网") { services.speech.reachableSince == nil }
        let toCue = try await sayToCue(workspace, "顺便看看登录回调")
        let toSession = try await sayToSession(workspace, target, "改完再跑一遍")
        func trips() async throws -> [Speech.Trip] { [try await trip(of: toCue, services), try await trip(of: toSession, services)] }

        #expect(try await trips() == [.sending, .sending])
        try await eventually("会话行是发送中") { row(services)?.status == .delivery(.inTransit(.sending)) }

        try await eventually("在等回执时按节奏拉") { app.sync.syncNows > 0 }
        try await clock.waitForSleeper()
        clock.advance(.seconds(121))
        #if os(iOS)
        try await eventually("拉取窗口走完") { clock.sleeperCount == 0 }  // 醒来时已过两分钟，不再拉
        #else
        try await eventually("拉取醒来又睡下") { app.sync.syncNows > 1 && clock.sleeperCount > 0 }  // Mac 在等就一直拉
        #endif
        #expect(try await trips() == [.sending, .sending])
        #expect(row(services)?.status == .delivery(.inTransit(.sending)))
        #expect(services.liveSessions.undelivered["atlas"] == nil)
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

        clock.advance(.seconds(Speech.sendLimit - 1))
        #expect(try await trips() == [.sending, .sending])
        #expect(try await presence(services) == .sending(.sending))
        // 同步通着也不能凭缺少上传回执断言未交出：对 Cue 说的是未确认；投送请求按自己的派发期限，还在路上
        clock.advance(.seconds(1))
        let since = try #require(services.speech.reachableSince)
        try await eventually("发送等待到点") { services.speech.now >= since.addingTimeInterval(Speech.sendLimit) }
        let cueTrip = try await trip(of: toCue, services)
        #expect(cueTrip.failure == nil && !cueTrip.inTransit && cueTrip != .delivered)
        #expect(try await trip(of: toSession, services) == .sending)
        #expect(Speech.undelivered(try await store.deliveryRequests(), at: services.speech) == 0)
        await workspace.resend(.cue(toCue, host: "mac-cue"), restoringInto: Bindable(workspace.cue).draft).value
        #expect(workspace.notice?.isError == true)
        #expect(try await store.cueMessages().contains { $0.id == toCue.id })
        await workspace.sayAgain(.cue(toCue, host: "mac-cue"), restoringInto: Bindable(workspace.cue).draft).value
        #expect(try await store.cueMessages().contains { $0.id == toCue.id })
    }

    @Test(arguments: ["future-outcome", "unconfirmed"])
    func 不认识或缺原因的未确认状态不冒充失败_显式再说保留原请求(status: String) async throws {
        let cloud = WeakCloud { [clock] in clock.now }
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!, workspace = Workspace(services: app.services)
        defer { services.cancelBackgroundWork() }
        let target = try await session(in: services.store)
        services.startSync()
        services.startLiveSessions()
        try await eventually("同步通了") { services.syncing.state.status == .idle && services.syncing.state.reconciled }
        let request = try await sayToSession(workspace, target, "继续一次检查")
        try await eventually("服务器收下请求") { await cloud.holds(request.id) }
        try await cloud.macAnswers(request.id, status: status)
        await services.syncing.syncNow()
        let current = try #require(try await services.store.deliveryRequest(request.id))
        #expect(current.status.rawValue == status)
        let result = Said.request(current).trip(at: services.speech)
        #expect(current.failure == nil)
        #expect(result.failure == nil && !result.inTransit && result != .delivered)
        #expect(result.unconfirmedReason?.contains("可能已经执行") == true)
        #expect(result.unconfirmedReason?.contains("已交给 Agent") == false)
        try await eventually("会话行收到未知状态") { row(services)?.label == "送达未确认" }
    }

}
