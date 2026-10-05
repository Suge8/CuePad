import CueSync
import Foundation

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
    /// 立即上传这一条记录（不等引擎调度）
    func sendNow(recordName: String) async throws
    func resolve(_ resolution: SyncResolution) async throws
}

extension CloudSync: SyncControlling {}
