#if os(macOS)
import CueStore
import Foundation

/// Codex 会话文件（`<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<时间>-<会话 id>.jsonl`）的逐行解码。
enum CodexHistory {
    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        // TODO(codex)
    }
}
#endif
