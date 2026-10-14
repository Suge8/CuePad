import CueStore
import CueSync
import Foundation
import SQLite3

extension DebugScene {
    /// `-CuePadSync <noAccount|decide|failed|syncing|restricted|conflicts>`：设置里 iCloud 同步那一行按这个状态显示（两端都认）。
    /// 隔离库没有同步引擎、真实状态出不来，状态直接写进服务；`failed` 带两条没能同步的记录，`conflicts` 在演示库里造一份冲突副本。
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

    /// 库里没有创建冲突副本的公开入口（由同步引擎产生）：拿最近改过的一张灵感，复制一份改过的正文，直接在库文件里把副本指回原卡。
    private static func seedConflict(_ services: AppServices) async {
        let store = services.store
        var original: Card?
        for project in (try? await store.projects()) ?? [] where original == nil {
            original = try? await store.cards(in: project.id).first
        }
        guard let original, let copy = try? await store.createCard(in: original.projectID, body: original.body + "\n另一台设备上补了一句")
        else { return }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(services.location.databaseURL.path, &handle) == SQLITE_OK else { return }
        let sql = "UPDATE cards SET conflictOf = '\(original.id.uuidString.lowercased())' WHERE id = '\(copy.id.uuidString.lowercased())'"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { return }
        // 与有同步引擎时一样跟着库走（`AppServices.startSync`）：选好保留哪份，这一行就消失
        Task {
            for try await conflicts in store.observe({ try $0.conflicts() }) { services.setConflicts(conflicts) }
        }
    }
}
