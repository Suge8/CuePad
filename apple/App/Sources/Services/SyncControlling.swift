import CueSync
import Foundation
import os

/// App 层用到的同步能力：真实实现是 `CloudSync`，测试用记录型替身（真同步需要 iCloud 权限与账号）。
/// 不隶属主线程：退出收尾在主线程被占住时也要能停下同步。
nonisolated protocol SyncControlling: Sendable {
    var stateUpdates: AsyncStream<SyncState> { get }
    /// 之后每次服务器收下本机的一批改动给出一个（实时层据此按门铃）
    var acceptedUpdates: AsyncStream<AcceptedChanges> { get }
    func start() async
    func stop() async
    /// 立即拉一次（返回时拉完；在拉的排上合成一拉，同步开始前来的等开始了再拉），顺带让待推送发一轮（不等）：
    /// 立即同步、回到前台、按节奏的拉取、收到推送、门铃都只调它（经 `pull`）
    func syncNow() async throws
    /// 马上传这一条（不进攒批窗口、不等后台那批），返回时它有了结果：服务器收下为 true
    func send(recordName: String) async -> Bool
    /// 把待推送全部发出去，返回时这一轮结束
    func push() async
    func resolve(_ resolution: SyncResolution) async throws
}

extension CloudSync: SyncControlling {}

nonisolated extension SyncControlling {
    /// 替身不发：只有真的同步有服务器收下这回事。
    var acceptedUpdates: AsyncStream<AcceptedChanges> { AsyncStream { _ in } }

    /// 拉一次（`syncNow`），失败（多半是离线）只记日志：下一次触发会再拉，状态变化经同步状态反映。
    /// 不在调用方的线程上跑（`@concurrent`）：从主线程来的（推送、立即同步）也当场离开主线程，主线程忙时拉取不跟着晚。
    @concurrent
    func pull() async {
        do {
            try await syncNow()
        } catch {
            Logger(subsystem: AppIdentity.id, category: "services").notice("拉取失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 马上只传这一条，不等提交触发的合并窗口，也不等后台那批（`CloudSync.send`）。`deleted`：本机删掉了它，传的是删除
    /// （传什么由库推导，这里只用于日志）。没传成的只记日志，之后照常重试。返回时这一条已经传完（或没传成）。
    func upload(_ record: UUID, deleted: Bool = false) async {
        let log = Logger(subsystem: AppIdentity.id, category: "services"), began = Date.now
        let what = deleted ? "删除" : "上传"
        if await send(recordName: record.uuidString.lowercased()) {
            log.info("立即\(what, privacy: .public) \(record.uuidString.prefix(8), privacy: .public) 用时 \(Date.now.timeIntervalSince(began), format: .fixed(precision: 1)) 秒")
        } else {
            log.notice("立即\(what, privacy: .public) \(record.uuidString.prefix(8), privacy: .public) 没传成，稍后自动重试")
        }
    }
}
