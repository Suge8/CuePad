import CloudKit
import CueStore
@testable import CueSync
import Foundation
import Testing
@testable import CuePad

/// App 层接入同步：启动引擎、镜像状态与问题、激活时立即同步、冲突与决定经 AppServices 交给界面。
struct SyncWiringTests {
    let app = TestApp()
    var services: AppServices { app.services }

    @Test func 启动同步_状态与问题镜像给界面() async throws {
        #expect(services.syncStatus == .starting)  // 引擎确认账号前不是"已同步"
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("app.sync.started == 1") { app.sync.started == 1 }

        app.sync.emit(SyncState(status: .syncing, issues: []))
        try await eventually("services.syncStatus == .syncing") { services.syncStatus == .syncing }

        let issue = SyncIssue(recordType: "attachments", recordName: "c1", problem: .damaged, detail: "附件记录没有文件")
        app.sync.emit(SyncState(status: .syncing, issues: [issue]))
        try await eventually("services.syncIssues == [issue]") { services.syncIssues == [issue] }

        app.sync.emit(SyncState(status: .syncing, issues: [], alerts: .failed("没有网络")))
        try await eventually("services.alertSubscription == .failed(\"没有网络\")") { services.alertSubscription == .failed("没有网络") }

        app.sync.emit(SyncState(status: .needsDecision(.accountSwitched), issues: [issue]))
        try await eventually("services.syncStatus == .needsDecision(.accountSwitched)") { services.syncStatus == .needsDecision(.accountSwitched) }
    }

    /// 真实的同步代码连内存里的 iCloud 替身（`SimulatedCloud`），从 AppServices 启动：云端最低对端版本高于这台时，
    /// 设置里说要更新、立即同步按不了，本机照记，改动不上传。
    @Test
    func 云端门槛高于这台时_提示更新_本机照记_改动不上传() async throws {
        let cloud = SimulatedCloud([Self.floor(CueStore.supportedSchemaVersions.upperBound + 1)])
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!
        services.startSync()
        defer { services.cancelBackgroundWork() }

        try await eventually("提示更新") { services.syncStatus == .outdated }
        #expect(SyncSummary(services.syncStatus).title == "这台的 CuePad 要更新")
        #expect(!services.canSyncNow)

        let card = try await Workspace(services: services).createCard(body: "要更新时照记", in: Project.defaultID)
        await services.upload(card.id)
        #expect(try await services.store.card(card.id)?.body == "要更新时照记")
        #expect(await cloud.saved.isEmpty)
    }

    /// 云端门槛低于这台要求的（能打开的最老库）：先把门槛抬上去，之后才传内容；别的设备换了更新的版本、把门槛抬过这台，
    /// 拉到就停下提示更新，之后的改动不再上传。
    @Test
    func 门槛先抬再传内容_别的设备抬过这台后停下不再上传() async throws {
        let cloud = SimulatedCloud([Self.floor(CueStore.peerFloor - 1)])
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!
        let workspace = Workspace(services: services)
        services.startSync()
        defer { services.cancelBackgroundWork() }

        let before = try await workspace.createCard(body: "门槛之后才传", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(before.id.uuidString.lowercased()) }
        let saved = await cloud.saved
        #expect(saved.first == PeerFloor.recordType)
        #expect(PeerFloor.version(in: await cloud.records([PeerFloor(zoneID: CloudSync.zoneID).id])) == CueStore.peerFloor)

        await cloud.put(Self.floor(CueStore.supportedSchemaVersions.upperBound + 1))
        await services.syncNow()
        try await eventually("拉到就停下") { services.syncStatus == .outdated }
        let after = try await workspace.createCard(body: "停下之后写的", in: Project.defaultID)
        await services.upload(after.id)
        #expect(await cloud.saved == saved)
        #expect(try await services.store.card(after.id)?.body == "停下之后写的")
    }

    /// 换了 iCloud 账号：停下等你决定，决定之前记的不上传。选上传本机，本机的都传给新账号；选清掉本机，同步的数据清掉，
    /// 本机的 Pi 会话索引（与账号无关）留着。
    @Test(.timeLimit(.minutes(1)), arguments: [SyncResolution.uploadLocal, .eraseLocal])
    func 换了iCloud账号_停下等你决定(_ resolution: SyncResolution) async throws {
        let cloud = SimulatedCloud([Self.floor(CueStore.peerFloor)])
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!
        let workspace = Workspace(services: services)
        services.startSync()
        defer { services.cancelBackgroundWork() }
        let before = try await workspace.createCard(body: "换账号前记的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(before.id.uuidString.lowercased()) }
        try await services.store.upsertPiSession(IndexedSession(id: "s1", path: "/p", cwd: "/c", lastActivityAt: .now), host: "mac-a")

        await cloud.signIn("另一个账号")
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        try await eventually("要你决定") { services.syncStatus == .needsDecision(.accountSwitched) }
        let waiting = try await workspace.createCard(body: "决定之前记的", in: Project.defaultID)
        await services.upload(waiting.id)
        #expect(await !cloud.saved.contains(waiting.id.uuidString.lowercased()))

        try await services.resolveSync(resolution)
        let ids = [before.id, waiting.id].map { CKRecord.ID(recordName: $0.uuidString.lowercased(), zoneID: CloudSync.zoneID) }
        switch resolution {
        case .uploadLocal:
            try await eventually("本机的都传给新账号") { await cloud.records(ids).count == 2 }
        case .eraseLocal:
            #expect(try await services.store.card(before.id) == nil)
            #expect(try await services.store.card(waiting.id) == nil)
            #expect(try await services.store.piSessions().map(\.id) == ["s1"])
            #expect(await cloud.records(ids).isEmpty)
        }
    }

    private static func floor(_ version: Int) -> CKRecord {
        let record = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
        record[PeerFloor.field] = version as NSNumber
        return record
    }

    /// 同步一直不返回（引擎队列被占着、网络没有回音）：下拉刷新的圈到时限就停，同步仍挂着；转着的时候主线程照常响应（测试本身在主线程上推钟）。
    @Test
    func 同步一直不返回时_下拉刷新到时限就停() async {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        app.sync.syncNowHangs.withLock { $0 = true }
        let refresh = Task { await app.services.syncNow() }
        await clock.waitForSleeper()
        #expect(app.services.isSyncingNow)

        clock.advance(AppServices.syncWaitLimit)
        await refresh.value

        #expect(!app.services.isSyncingNow)
        #expect(app.sync.syncNows == 1)
    }

    @Test func 冲突副本经AppServices暴露_选定版本后消失() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        let original = try await services.store.createCard(body: "原卡")
        let copy = try await services.store.createCard(body: "副本")
        #expect(DebugScene.markConflict(copy: copy.id, of: original.id, database: services.location.databaseURL))
        _ = try await services.store.createCard(body: "触发一次重读")

        try await eventually("services.conflicts.count == 1") { services.conflicts.count == 1 }
        #expect(services.conflicts.map(\.copy.body) == ["副本"])

        try await services.resolveConflict(copy: copy.id, keep: .original)
        try await eventually("services.conflicts.isEmpty") { services.conflicts.isEmpty }
    }

    @Test func 正式组装没有创建同步时状态写明原因() {
        let app = TestApp(sync: .iCloud)  // 测试宿主在隔离目录里
        #expect(app.services.sync == nil)
        guard case .unavailable(let reason) = app.services.syncStatus else {
            Issue.record("没有引擎却不是 unavailable：\(app.services.syncStatus)")
            return
        }
        #expect(reason.contains("隔离"))
    }
}
