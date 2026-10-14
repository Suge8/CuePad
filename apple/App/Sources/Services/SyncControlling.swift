import CueSync
import Foundation
import os

/// App 层用到的同步引擎能力：真实实现是 `CloudSync`，测试用记录型替身（真引擎需要 iCloud 权限与账号）。
/// 不隶属主线程：退出收尾在主线程被占住时也要能停下引擎。
nonisolated protocol SyncControlling: Sendable {
    var stateUpdates: AsyncStream<SyncState> { get }
    func start() async throws
    func stop() async
    func syncNow() async throws
    /// 直接向服务器拉一次同步区的变化（推送之外的主动拉取，见 `CloudSync.pullChanges`）
    func pullChanges() async throws
    /// 还没有主动拉取的令牌就先取
    func preparePull() async throws
    /// 立即上传这一条记录（不等引擎调度）；`deleted` 时上传的是删除
    func sendNow(recordName: String, deleted: Bool) async throws
    func resolve(_ resolution: SyncResolution) async throws
}

extension CloudSync: SyncControlling {}

nonisolated extension SyncControlling {
    /// 立即只上传这一条记录，不等引擎的自动调度（几秒到几十秒），也不排在引擎正在做的事后面（`CloudSync.sendNow`）。
    /// 失败只记日志，引擎会照常重试。返回时这一条已经传完（或失败）。
    func upload(_ record: UUID, deleted: Bool = false) async {
        let log = Logger(subsystem: AppServices.bundleID, category: "services"), began = Date.now
        do {
            try await sendNow(recordName: record.uuidString.lowercased(), deleted: deleted)
            log.info("立即上传 \(record.uuidString.prefix(8), privacy: .public) 用时 \(Date.now.timeIntervalSince(began), format: .fixed(precision: 1)) 秒")
        } catch {
            log.notice("立即上传记录失败，等引擎自动上传：\(error.localizedDescription, privacy: .public)")
        }
    }
}
