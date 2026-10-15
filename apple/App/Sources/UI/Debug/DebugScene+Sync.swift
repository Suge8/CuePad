#if DEBUG
import CueStore
import CueSync
import Foundation
import SQLite3

extension DebugScene {
    /// `-CuePadSync stalled`：装上拉取永不返回的同步替身（隔离库本来没有同步），核对下拉刷新的圈有时限、界面不跟着卡。
    /// `-CuePadSync offline`：一开始连不上 iCloud，`-CuePadOfflineSeconds`（默认 6）秒后恢复；配 `-CuePadDemoMac YES` 与
    /// `-CuePadSpeech send` 录"断网时说 → 同步不通 → 恢复 → 送达"（演示 Mac 断网时不接手）。
    static var syncSource: AppServices.SyncSource {
        switch defaults.string(forKey: "CuePadSync") {
        case "stalled": .custom(StalledSync())
        case "offline": .custom(OfflineSync(seconds: defaults.object(forKey: "CuePadOfflineSeconds") as? Double ?? 6))
        default: .iCloud
        }
    }

    /// 先报连不上 iCloud，过一会儿报已同步；拉取与上传什么都不做。
    nonisolated final class OfflineSync: SyncControlling {
        let seconds: Double
        init(seconds: Double) { self.seconds = seconds }
        var stateUpdates: AsyncStream<SyncState> {
            AsyncStream { [seconds] continuation in
                continuation.yield(SyncState(status: .offline, issues: []))
                let task = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    continuation.yield(SyncState(status: .idle, issues: []))
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func start() async throws {}
        func stop() async {}
        func syncNow() async throws {}
        func send(recordName: String) async -> Bool { true }
        func push() async {}
        func resolve(_ resolution: SyncResolution) async throws {}
    }

    /// 立即同步不返回（像网络一直没有回音），其余什么都不做。
    nonisolated final class StalledSync: SyncControlling {
        var stateUpdates: AsyncStream<SyncState> { AsyncStream { $0.yield(SyncState(status: .idle, issues: [])) } }
        func start() async throws {}
        func stop() async {}
        func syncNow() async throws { try await Task.sleep(for: .seconds(86_400)) }
        func send(recordName: String) async -> Bool { true }
        func push() async {}
        func resolve(_ resolution: SyncResolution) async throws {}
    }

    /// `-CuePadSync <noAccount|decide|failed|syncing|restricted|conflicts>`：设置里 iCloud 同步那一行按这个状态显示（两端都认）。
    /// 隔离库没有同步、真实状态出不来，状态直接写进服务；`failed` 带两条没能同步的记录，`conflicts` 在演示库里造一份冲突副本。
    static func presetSync(_ services: AppServices) async {
        let issues = [
            SyncIssue(recordType: "Card", recordName: "A1B2", message: "CKError 14: server record changed"),
            SyncIssue(recordType: "Attachment", recordName: "9F3E", message: "CKError 27: asset file not found"),
        ]
        switch defaults.string(forKey: "CuePadSync") {
        case "noAccount": services.setSyncState(SyncState(status: .noAccount, issues: []))
        case "decide": services.setSyncState(SyncState(status: .needsDecision(.accountSwitched), issues: []))
        case "failed": services.setSyncState(SyncState(status: .failed("同步出错"), issues: issues))
        case "syncing": services.setSyncState(SyncState(status: .syncing, issues: []))
        case "restricted": services.setSyncState(SyncState(status: .accountRestricted, issues: []))
        case "conflicts":
            services.setSyncState(SyncState(status: .idle, issues: []))
            await seedConflict(services)
        default: break
        }
    }

    /// 拿演示库里的一张灵感，复制一份改过的正文，标成它的冲突副本。
    private static func seedConflict(_ services: AppServices) async {
        let store = services.store
        var original: Card?
        for project in (try? await store.projects()) ?? [] where original == nil {
            original = try? await store.cards(in: project.id).first
        }
        guard let original, let copy = try? await store.createCard(in: original.projectID, body: original.body + "\n另一台设备上补了一句")
        else { return }
        guard markConflict(copy: copy.id, of: original.id, database: services.location.databaseURL) else { return }
        // 与有同步时一样跟着库走（`AppServices.startSync`）：选好保留哪份，这一行就消失
        Task {
            for try await conflicts in store.observe({ try $0.conflicts() }) { services.setConflicts(conflicts) }
        }
    }

    /// 库里没有创建冲突副本的公开入口（由同步产生）：直接在库文件里把副本指回原卡。演示与测试共用这一处。
    static func markConflict(copy: UUID, of original: UUID, database: URL) -> Bool {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { return false }
        let sql = "UPDATE cards SET conflictOf = '\(original.uuidString.lowercased())' WHERE id = '\(copy.uuidString.lowercased())'"
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }
}
#endif
