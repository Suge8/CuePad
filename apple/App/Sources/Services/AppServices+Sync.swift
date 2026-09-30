import CueStore
import CueSync
import Foundation

/// iCloud 同步的 App 层接入：启动引擎、把状态与冲突交给界面、激活时立即同步。
extension AppServices {
    /// 隔离模式（`CUEPAD_LIBRARY_DIR`）不同步：它用于开发与验收，不能碰真实账号的云端数据。
    static func makeSync(store: CueStore, location: LibraryLocation) -> (any SyncControlling)? {
        location.isIsolated ? nil : CloudSync(store: store)
    }

    /// 启动引擎，并让 `syncStatus`、`syncIssues`、`conflicts` 跟随，直到任务取消。没有引擎（隔离模式）什么都不做。
    func startSync() {
        guard let sync else { return }
        tasks.append(Task {
            for await status in sync.statusUpdates { await applySyncStatus(status, from: sync) }
        })
        tasks.append(Task {
            do {
                try await sync.start()
            } catch {
                reportIssue(.syncUnavailable("同步没能启动：\(error)"))
            }
        })
        tasks.append(Task {
            do {
                for try await conflicts in store.observe([.cards], { try $0.conflicts() }) { setConflicts(conflicts) }
            } catch {
                reportIssue(.syncUnavailable("冲突列表读取失败：\(error)"))
            }
        })
        #if os(macOS)
        startWakeSync()
        #endif
    }

    /// 应用回到前台：立即同步（推送之外的兜底）。
    func handleActivation() async {
        await syncNow()
    }

    /// 立即拉取并推送。失败（多半是离线）只记日志：引擎自己会重试，状态变化会经 `syncStatus` 反映。
    func syncNow() async {
        guard let sync else { return }
        do {
            try await sync.syncNow()
        } catch {
            Self.log.notice("立即同步失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 处理 `syncStatus == .needsDecision`：用户选择后引擎重新开始。
    func resolveSync(_ resolution: SyncResolution) async throws {
        try await sync?.resolve(resolution)
    }

    /// 冲突副本：选定保留的版本，另一份删除。
    func resolveConflict(copy id: UUID, keep choice: ConflictChoice) async throws {
        try await store.resolveConflict(copy: id, keep: choice)
    }

    private func applySyncStatus(_ status: SyncStatus, from sync: any SyncControlling) async {
        setSyncState(status: status, issues: await sync.issues)
    }
}
