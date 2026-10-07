#if os(macOS)
import CuePi
import Foundation

/// 后台托管 Pi 的接缝（真实实现是 `PiHost`，测试换成只记录参数的替身）：返回连上桥的会话 id。
@MainActor
protocol PiHosting: AnyObject {
    func start()
    /// 关掉所有托管进程；返回的等待在它们都退出后结束。
    func closeAll() -> @concurrent @Sendable () async -> Void
    func resume(sessionFile: URL, in directory: URL, executable: URL) async throws -> CuePi.PiSession.ID
    func open(in directory: URL, launchToken: String, executable: URL) async throws -> CuePi.PiSession.ID
    /// 结束一个在线会话，等它真的退出。
    func end(_ id: CuePi.PiSession.ID) async throws
}

extension PiHost: PiHosting {
    func resume(sessionFile: URL, in directory: URL, executable: URL) async throws -> CuePi.PiSession.ID {
        try await resume(sessionFile: sessionFile, in: directory, executable: executable).id
    }

    func open(in directory: URL, launchToken: String, executable: URL) async throws -> CuePi.PiSession.ID {
        try await open(in: directory, launchToken: launchToken, executable: executable).id
    }
}
#endif
