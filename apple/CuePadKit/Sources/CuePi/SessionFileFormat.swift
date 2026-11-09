#if os(macOS)
import CueStore
import CueText
import Foundation

extension UnsafeRawBufferPointer {
    /// 不拷贝的 `Data` 视图，只在这次 `Ingest` 调用里有效；空行为 nil。
    var borrowedData: Data? {
        guard let base = baseAddress, !isEmpty else { return nil }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: count, deallocator: .none)
    }
}

struct SessionFileFormat: Sendable {
    /// 损坏或不认识的行跳过。
    typealias Ingest = @Sendable (UnsafeRawBufferPointer, inout PiHistoryCheckpoint, inout PiHistory.Transcript) throws -> Void

    enum Naming: Sendable {
        /// 文件名以会话 id 结尾（Pi 的 `<时刻>_<id>.jsonl`、Codex 的 `rollout-<时刻>-<id>.jsonl`）：会话文件先建出来、文件头随后才写，
        /// 读到文件头之前它还不是会话——按文件名记下会多出一条没名字的孤儿会话
        case idSuffix
        case id
        /// 一个会话一个目录、目录名是 id，里面的会话文件叫 `file`（dsh 的 `<id>/session.v4.jsonl`，同目录里别的代际不认；
        /// Grok 的 `<id>/updates.jsonl`）。`cwdInPath`：上一层目录名是百分号编码的工作目录（Grok）；dsh 的那层编码不可逆，工作目录只从文件头读
        case inDirectory(file: String, cwdInPath: Bool = false)
    }

    let ingest: Ingest
    /// 会话文件在会话目录下第几层，与各家自己的会话列表一致：Pi 与 Claude Code 是 `<项目目录>/*.jsonl`（更深的，如子代理的
    /// `<项目目录>/…/subagents/*.jsonl`，不是会话列表里的会话）；Codex 是 `YYYY/MM/DD/rollout-*.jsonl`；dsh 是 `<项目目录>/<id>/session.v4.jsonl`；
    /// Grok 是 `<工作目录>/<id>/updates.jsonl`。
    let depth: Int
    let naming: Naming
    var sidecar: Sidecar?

    /// 另存会话名的文件：每次读会话文件都读它一次，取到的是 Agent 此刻的会话名（你起的或它自己起的，分不出），盖过会话文件里读到的。
    /// 它会在会话文件不动时单独变（一轮结束后才起好名、改名不写会话文件）：索引器也盯着它、按它的修改时间认会话文件读没读过（`PiHistoryIndexer`）。
    struct Sidecar: Sendable {
        let file: @Sendable (_ sessionFile: URL) -> URL
        let name: @Sendable (_ contents: Data, _ sessionID: String) -> String?
    }
    let directory: @Sendable (AgentPaths) -> URL

    func matches(_ file: URL) -> Bool {
        switch naming {
        case .idSuffix, .id: file.pathExtension == "jsonl"
        case .inDirectory(let name, _): file.lastPathComponent == name
        }
    }

    func sessionID(of file: URL) -> String {
        switch naming {
        case .idSuffix: String(file.deletingPathExtension().lastPathComponent.suffix(Self.idLength))
        case .id: file.deletingPathExtension().lastPathComponent
        case .inDirectory: file.deletingLastPathComponent().lastPathComponent
        }
    }

    func cwd(of file: URL) -> String? {
        guard case .inDirectory(_, true) = naming else { return nil }
        return file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.removingPercentEncoding
    }

    func isSession(_ checkpoint: PiHistoryCheckpoint) -> Bool {
        if case .id = naming { return true }
        return checkpoint.sessionID != nil
    }

    private static let idLength = 36
}
#endif
