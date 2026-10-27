#if os(macOS)
import CueStore
import CueText
import Foundation

/// 一家 Agent 的会话文件在哪、怎么认、怎么读（`AgentFacts.sessionFiles`）。
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
    /// 每个会话一个目录、会话记录是其中这个名字的文件（Grok：`<会话目录>/<百分号编码的工作目录>/<会话 id>/updates.jsonl`）；
    /// nil 是会话记录就是 `.jsonl` 文件、文件名以会话 id 结尾（Pi `<时刻>_<id>`、Claude Code `<id>`、Codex `rollout-<时刻>-<id>`）
    var fileName: String? = nil
    /// 会话目录（`AgentPaths.sessionsDirectory`）
    let directory: @Sendable (AgentPaths) -> URL

    func isSessionFile(_ file: URL) -> Bool { fileName.map { file.lastPathComponent == $0 } ?? (file.pathExtension == "jsonl") }

    /// 路径里的会话 id：文件名的末尾，或会话自己的目录名。
    func sessionID(of file: URL) -> String {
        guard fileName != nil else { return String(file.deletingPathExtension().lastPathComponent.suffix(Self.idLength)) }
        return file.deletingLastPathComponent().lastPathComponent
    }

    /// 路径里的工作目录（每个会话一个目录的，上一层是它百分号编码的工作目录）；别的为 nil。
    func cwd(of file: URL) -> String? {
        guard fileName != nil else { return nil }
        return file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.removingPercentEncoding
    }

    private static let idLength = 36

    /// 读到 `checkpoint` 为止算不算一个会话：Pi、Codex 的会话文件先建出来、文件头随后才写，读到文件头之前它还不是会话（文件名不是会话 id），
    /// 索引器不发出它——按文件名记下会多出一条没名字的孤儿会话。文件名就是会话 id 的（Claude Code）总算。
    func isSession(_ checkpoint: PiHistoryCheckpoint) -> Bool { checkpoint.sessionID != nil || nameIsSessionID }
}
#endif
