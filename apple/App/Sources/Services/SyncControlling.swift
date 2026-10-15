import CueSync
import Foundation
import os

/// App 层用到的同步能力：真实实现是 `CloudSync`，测试用记录型替身（真同步需要 iCloud 权限与账号）。
/// 不隶属主线程：退出收尾在主线程被占住时也要能停下同步。
nonisolated protocol SyncControlling: Sendable {
    var stateUpdates: AsyncStream<SyncState> { get }
    func start() async throws
    func stop() async
    /// 立即拉一次（返回时拉完），顺带把待推送发出去（不等）：立即同步、回到前台、按节奏的拉取、收到推送都只调它
    func syncNow() async throws
    /// 马上传这一条（排在最前），返回时它所在的那一批有了结果：服务器收下为 true
    func send(recordName: String) async -> Bool
    /// 把待推送全部发出去，返回时这一轮结束
    func push() async
    func resolve(_ resolution: SyncResolution) async throws
}

extension CloudSync: SyncControlling {}

nonisolated extension SyncControlling {
    /// 马上只传这一条，不等提交触发的合并窗口，排在其余待推送前面（`CloudSync.send`）。`deleted`：本机删掉了它，传的是删除
    /// （传什么由库推导，这里只用于日志）。没传成的只记日志，之后照常重试。返回时这一条已经传完（或没传成）。
    func upload(_ record: UUID, deleted: Bool = false) async {
        let log = Logger(subsystem: AppServices.bundleID, category: "services"), began = Date.now
        let what = deleted ? "删除" : "上传"
        if await send(recordName: record.uuidString.lowercased()) {
            log.info("立即\(what, privacy: .public) \(record.uuidString.prefix(8), privacy: .public) 用时 \(Date.now.timeIntervalSince(began), format: .fixed(precision: 1)) 秒")
        } else {
            log.notice("立即\(what, privacy: .public) \(record.uuidString.prefix(8), privacy: .public) 没传成，稍后自动重试")
        }
    }
}
