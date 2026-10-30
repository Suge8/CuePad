#if os(macOS)
import CueStore
import Foundation

extension PiHistory {
    /// 立即读一次指定文件，之后只随真实文件事件增量读。nil 是文件尚未出现或已移除，不是送达失败。
    /// 与目录索引共用解析规则；这里只保留本次订阅的检查点，不写目录索引的进度。
    public static func following(file: URL, agent: AgentKind, files: AttachmentFiles) -> PiHistoryFollowing {
        let (updates, continuation) = AsyncThrowingStream<PiHistoryUpdate?, Error>.makeStream()
        let task = Task { await follow(file: file, agent: agent, files: files, into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return PiHistoryFollowing(updates: updates, worker: task)
    }

    @concurrent private static func follow(
        file: URL, agent: AgentKind, files: AttachmentFiles, into continuation: AsyncThrowingStream<PiHistoryUpdate?, Error>.Continuation
    ) async {
        let follower = FileFollower()
        defer { follower.stop() }
        follower.follow(only: [file.realPath.path])
        var checkpoint: PiHistoryCheckpoint?
        do {
            for await path in follower.paths {
                try Task.checkCancellation()
                do {
                    let update = try index(file: URL(filePath: path), agent: agent, from: checkpoint, files: files)
                    checkpoint = update.checkpoint
                    continuation.yield(update)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    checkpoint = nil
                    continuation.yield(nil)
                }
            }
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
}

/// 有明确所有者的一次文件订阅；早于到期读到正证据时也收齐后台读取，不留下监听。
public struct PiHistoryFollowing: Sendable {
    public let updates: AsyncThrowingStream<PiHistoryUpdate?, Error>
    fileprivate let worker: Task<Void, Never>

    public func stop() async {
        worker.cancel()
        await worker.value
    }
}
#endif
