import CueSync
import Foundation

/// App 层用到的同步引擎能力：真实实现是 `CloudSync`，测试用记录型替身（真引擎需要 iCloud 权限与账号）。
/// 不隶属主线程：退出收尾在主线程被占住时也要能停下引擎。
nonisolated protocol SyncControlling: Sendable {
    var stateUpdates: AsyncStream<SyncState> { get }
    func start() async throws
    func stop() async
    func syncNow() async throws
    /// 只拉一次服务器的变化（推送之外的主动拉取）
    func fetchChanges() async throws
    func resolve(_ resolution: SyncResolution) async throws
}

extension CloudSync: SyncControlling {}
