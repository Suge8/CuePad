#if os(macOS)
import CueStore
import CueText
import Foundation

/// 一家 Agent 的会话文件怎么认、怎么读：唯一的一处（会话目录本身在 `AgentPaths.sessionsDirectory`）。OpenCode 的会话在它的数据库里，没有。
struct SessionFileFormat: Sendable {
    /// 一行会话文件（不含换行）的解码：经检查点上的那几个变化（`said`、`answered`……）更新摘要与轮次，你的话与每轮的回答加进对话。
    /// 损坏或不认识的行跳过。
    typealias Ingest = @Sendable (UnsafeRawBufferPointer, inout PiHistoryCheckpoint, inout PiHistory.Transcript) throws -> Void

    let ingest: Ingest
    /// 会话文件在会话目录下第几层，与各家自己的会话列表一致：Pi 与 Claude Code 是 `<项目目录>/*.jsonl`（更深的，如子代理的
    /// `<项目目录>/…/subagents/*.jsonl`，不是会话列表里的会话）；Codex 是 `YYYY/MM/DD/rollout-*.jsonl`。
    let depth: Int
    /// 文件名就是会话 id（Claude Code）：文件头还没读到也算会话
    let nameIsSessionID: Bool

    /// 读到 `checkpoint` 为止算不算一个会话：Pi、Codex 的会话文件先建出来、文件头随后才写，读到文件头之前它还不是会话（文件名不是会话 id），
    /// 索引器不发出它——按文件名记下会多出一条没名字的孤儿会话。文件名就是会话 id 的（Claude Code）总算。
    func isSession(_ checkpoint: PiHistoryCheckpoint) -> Bool { checkpoint.sessionID != nil || nameIsSessionID }

    static func of(_ agent: AgentKind) -> SessionFileFormat? {
        switch agent {
        case .pi: SessionFileFormat(ingest: PiHistory.ingest, depth: 2, nameIsSessionID: false)
        case .claudeCode: SessionFileFormat(ingest: ClaudeHistory.ingest, depth: 2, nameIsSessionID: true)
        case .codex: SessionFileFormat(ingest: CodexHistory.ingest, depth: 4, nameIsSessionID: false)
        case .opencode: nil
        }
    }
}
#endif
