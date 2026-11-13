import CloudKit
import CueStore
@testable import CueSync
import Foundation
import SQLite3
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SyncWiringTests {
    let app = TestApp()
    var services: AppServices { app.services }

    @Test(arguments: [true, false])
    func 同步的起点_有引擎先是正在开始_没有引擎是不可用并写原因(_ hasEngine: Bool) async throws {
        let app = hasEngine ? TestApp() : TestApp(sync: .iCloud)
        let services = app.services!
        guard hasEngine else {
            #expect(services.sync == nil)
            guard case .unavailable(let reason) = services.syncing.state.status else {
                Issue.record("没有引擎却不是 unavailable：\(services.syncing.state.status)")
                return
            }
            #expect(!reason.isEmpty)
            return
        }
        #expect(services.syncing.state.status == .starting)
        services.startSync()
        defer { services.cancelBackgroundWork() }
        try await eventually("app.sync.started == 1") { app.sync.started == 1 }
    }

    @Test
    func 云端门槛高于这台时_提示更新_本机照记_改动不上传() async throws {
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.supportedSchemaVersions.upperBound + 1)])
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!
        services.startSync()
        defer { services.cancelBackgroundWork() }

        try await eventually("提示更新") { services.syncing.state.status == .outdated }
        #expect(!services.syncing.canSyncNow)

        let card = try await Workspace(services: services).createCard(body: "要更新时照记", in: Project.defaultID)
        await services.upload(card.id)
        #expect(try await services.store.card(card.id)?.body == "要更新时照记")
        #expect(await cloud.saved.isEmpty)
    }

    @Test
    func 门槛先抬再传内容_别的设备抬过这台后停下不再上传() async throws {
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor - 1)])
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

        await cloud.put(CKRecord.peerFloor(CueStore.supportedSchemaVersions.upperBound + 1))
        await services.syncing.syncNow()
        try await eventually("拉到就停下") { services.syncing.state.status == .outdated }
        let after = try await workspace.createCard(body: "停下之后写的", in: Project.defaultID)
        await services.upload(after.id)
        #expect(await cloud.saved == saved)
        #expect(try await services.store.card(after.id)?.body == "停下之后写的")
    }

    @Test(arguments: [SyncResolution.uploadLocal, .eraseLocal])
    func 换了iCloud账号_停下等你决定(_ resolution: SyncResolution) async throws {
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)])
        let accountChanges = NotificationCenter()  // 全进程的通知会叫醒并行的别的测试
        let app = TestApp(sync: .built { CloudSync(store: $0, accountChanges: accountChanges) { cloud } })
        let services = app.services!
        let workspace = Workspace(services: services)
        services.startSync()
        defer { services.cancelBackgroundWork() }
        let before = try await workspace.createCard(body: "换账号前记的", in: Project.defaultID)
        try await eventually("传上去") { await cloud.saved.contains(before.id.uuidString.lowercased()) }
        try await services.store.upsertSession(IndexedSession(id: "s1", path: "/p", cwd: "/c", lastActivityAt: .now), host: "mac-a")

        await cloud.signIn("另一个账号")
        accountChanges.post(name: .CKAccountChanged, object: nil)
        try await eventually("要你决定") { services.syncing.state.status == .needsDecision(.accountSwitched) }
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
            #expect(try await services.store.indexedSessions().map(\.id) == ["s1"])
            #expect(await cloud.records(ids).isEmpty)
        }
    }

    /// 同步一直不返回（引擎队列被占着、网络没有回音）：下拉刷新的圈到时限就停，同步仍挂着；转着的时候主线程照常响应（测试本身在主线程上推钟）。
    @Test
    func 同步一直不返回时_下拉刷新到时限就停() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        app.sync.syncNowHangs.withLock { $0 = true }
        let refresh = Task { await app.services.syncing.syncNow() }
        try await clock.waitForSleeper()
        #expect(app.services.syncing.isSyncingNow)

        clock.advance(SyncDriver.syncWaitLimit)
        await refresh.value

        #expect(!app.services.syncing.isSyncingNow)
        #expect(app.sync.syncNows == 1)
    }

    @Test func 冲突副本经AppServices暴露_选定版本后消失() async throws {
        services.startSync()
        defer { services.cancelBackgroundWork() }
        let original = try await services.store.createCard(body: "原卡")
        let copy = try await services.store.createCard(body: "副本")
        try markConflict(copy: copy.id, of: original.id)
        _ = try await services.store.createCard(body: "触发一次重读")

        try await eventually("services.syncing.conflicts.count == 1") { services.syncing.conflicts.count == 1 }
        #expect(services.syncing.conflicts.map(\.copy.body) == ["副本"])

        try await services.syncing.resolveConflict(copy: copy.id, keep: .original)
        try await eventually("services.syncing.conflicts.isEmpty") { services.syncing.conflicts.isEmpty }
    }
    /// 冲突副本只由同步产生、没有公开入口：直接在库文件里把副本指回原卡。
    private func markConflict(copy: UUID, of original: UUID) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(services.location.databaseURL.path, &db) == SQLITE_OK)
        let sql = "UPDATE cards SET conflictOf = '\(original.uuidString.lowercased())' WHERE id = '\(copy.uuidString.lowercased())'"
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}
