#if os(macOS)
import CueStore
import Foundation

/// Claude Code 会话文件（`<配置目录>/projects/<编码后的工作目录>/<会话 id>.jsonl`）的逐行解码。
enum ClaudeHistory {
    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        // TODO(claude)
    }
}
#endif
