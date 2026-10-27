#if os(macOS)
import CueStore
import CueText
import Foundation

/// 一家 Agent 的会话文件在哪、怎么认、怎么读（`AgentFacts.sessionFiles`）。
struct SessionFileFormat: Sendable {
    /// 一行会话文件（不含换行）的解码：经检查点上的那几个变化（`said`、`answered`……）更新摘要与轮次，你的话与每轮的回答加进对话。
    /// 损坏或不认识的行跳过。
    typealias Ingest = @Sendable (UnsafeRawBufferPointer, inout PiHistoryCheckpoint, inout PiHistory.Transcript) throws -> Void

    /// 会话文件叫什么、会话 id 在哪
    enum Naming: Sendable {
        /// 文件名以会话 id 结尾（Pi 的 `<时刻>_<id>.jsonl`、Codex 的 `rollout-<时刻>-<id>.jsonl`）：会话文件先建出来、文件头随后才写，
        /// 读到文件头之前它还不是会话——按文件名记下会多出一条没名字的孤儿会话
        case idSuffix
        /// 文件名就是会话 id（Claude Code 的 `<id>.jsonl`）：文件头还没读到也算会话
        case id
        /// 一个会话一个目录、目录名是 id，里面的会话文件叫 `file`（dsh 的 `<id>/session.v4.jsonl`）；同目录里别的代际不认
        case inDirectory(file: String)
    }

    let ingest: Ingest
    /// 会话文件在会话目录下第几层，与各家自己的会话列表一致：Pi 与 Claude Code 是 `<项目目录>/*.jsonl`（更深的，如子代理的
    /// `<项目目录>/…/subagents/*.jsonl`，不是会话列表里的会话）；Codex 是 `YYYY/MM/DD/rollout-*.jsonl`；dsh 是 `<项目目录>/<id>/session.v4.jsonl`。
    let depth: Int
    let naming: Naming
    /// 会话目录（`AgentPaths.sessionsDirectory`）
    let directory: @Sendable (AgentPaths) -> URL

    func matches(_ file: URL) -> Bool {
        switch naming {
        case .idSuffix, .id: file.pathExtension == "jsonl"
        case .inDirectory(let name): file.lastPathComponent == name
        }
    }

    /// 从路径认出的会话 id（文件头还没读到时用它）。
    func sessionID(of file: URL) -> String {
        switch naming {
        case .idSuffix: String(file.deletingPathExtension().lastPathComponent.suffix(Self.idLength))
        case .id: file.deletingPathExtension().lastPathComponent
        case .inDirectory: file.deletingLastPathComponent().lastPathComponent
        }
    }

    /// 读到 `checkpoint` 为止算不算一个会话：文件名就是会话 id 的总算，其余要读到文件头。
    func isSession(_ checkpoint: PiHistoryCheckpoint) -> Bool {
        if case .id = naming { return true }
        return checkpoint.sessionID != nil
    }

    private static let idLength = 36
}
#endif
