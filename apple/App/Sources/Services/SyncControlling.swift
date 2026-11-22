import CueSync
import Foundation

nonisolated protocol SyncControlling: Sendable {
    var stateUpdates: AsyncStream<SyncState> { get }
    func start() async
    func stop() async
    @discardableResult func syncNow() async throws -> SyncPullResult
    func send(recordNames: Set<String>) async -> Bool
    func push() async
    /// 回到前台：iOS 上再认一次账号（挂起期间换的账号可能没有通知），Mac 只提前等着退避的那次（`CloudSync.activated`）
    func activated() async
    func resolve(_ resolution: SyncResolution) async throws
    var fileTransfers: AsyncStream<[String: FileTransfer]> { get }
    func fetchFile(_ key: String) async throws -> URL
}

extension CloudSync: SyncControlling {}

typealias FileFetching = @Sendable (String) async throws -> URL

nonisolated extension Optional where Wrapped == any SyncControlling {
    func fetchFile(_ key: String) async throws -> URL {
        guard let self else { throw FileFetchFailure.notSyncing }
        return try await self.fetchFile(key)
    }
}
