import CueSync
import Foundation

/// App 层用到的同步引擎能力：真实实现是 `CloudSync`，测试用记录型替身（真引擎需要 iCloud 权限与账号）。
protocol SyncControlling: Sendable {
    var stateUpdates: AsyncStream<SyncState> { get }
    func start() async throws
    func stop() async
    func syncNow() async throws
    func resolve(_ resolution: SyncResolution) async throws
}

extension CloudSync: SyncControlling {}
