#if os(macOS)
import CueStore
import Foundation

/// 没有自带语义会话名的会话（Pi 默认取首句、Codex 托管会话）按第一句话起的短名：由会话自己那一家起（数据只发给你本就在用的那家），只回不写；
/// 要不要起、起好后写不写由 App 定（`SessionNamer`：起名前与写回前各核对一次），写回走改名（Pi 扩展里即 Pi 的改名接口），名字照各家会话名回来。
public enum SessionNameSuggestion {
    /// 名字的长度上限（字符），同 Codex 终端界面起名（`THREAD_TITLE_MAX_CHARS`）。模型的回话取第一行、去掉首尾空白、截到这么长
    /// （Pi 扩展里同一条，上限随命令给）
    static let limit = 36
    /// 起一个名最多等这么久，过了就放弃：Pi 扩展要在桥等 ack 的时限（`AgentTimeouts.ack`）之内回话
    static let budget: Duration = .seconds(8)

    /// 给模型的说明，照 Codex 终端界面起名的那段（`thread_title_instructions`）：会话名也是给任务看板读的任务名。
    static let instructions = """
        Generate a concise, single-line task title of at most \(limit) characters and under five words where possible. \
        Start with an imperative verb. Capitalize only the first word unless the user's language, proper nouns, acronyms, \
        or code terms require otherwise. Preserve ticket references exactly. Write in the user's language. \
        Do not use quotes, markdown, or trailing punctuation. Do not answer the request.
        """

    static func cleaned(_ reply: String) -> String? {
        let line = reply.split(whereSeparator: \.isNewline).first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(limit)) } ?? ""
        return line.isEmpty ? nil : line
    }
}

extension PiBridge {
    public func canNameItself(_ id: PiSession.ID) -> Bool { controls[id]?.canNameItself(id) ?? false }

    /// 请会话那一家按它的第一句话起个短名（`SessionNameSuggestion`），不写回：还没有第一句话、这家起不了（抛 `unsupported`）、
    /// 起不出（超时、出错、空回答）都抛错。
    public func suggestName(for id: PiSession.ID) async throws -> String {
        guard let link = controls[id], let first = session(id: id)?.firstMessage else { throw PiBridgeError.unknownSession(id) }
        return try await link.suggestName(from: PiSessionName.display(name: nil, firstMessage: first, folder: ""), in: id)
    }
}
#endif
