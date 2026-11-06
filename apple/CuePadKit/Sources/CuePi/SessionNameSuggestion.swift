#if os(macOS)
import CueStore
import Foundation

/// 没有自带语义会话名的会话（Pi 默认取首句、Codex 托管会话）按第一句话起的短名：由会话自己那一家起、自己写回（数据只发给你本就在用的那家），
/// 写之前那家的会话已有名字（你在起名途中改了名）就不写；名字照各家会话名回来。要不要起由 App 定（只在你没起过名、绑着的任务没有标题时）。
/// - Pi：桥扩展用会话所在 provider 里最便宜的可用模型，用 Pi 的改名接口写回（`title.ts`）；
/// - Codex 托管：同 Codex 终端界面自动起名——在它自己的 app-server 里开用完不留的临时线程，模型 `gpt-5.6-luna`，`thread/name/set` 写回（`CodexRuntime+Naming`）。
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

    /// 模型的回话整理成会话名；空的为 nil。
    static func cleaned(_ reply: String) -> String? {
        let line = reply.split(whereSeparator: \.isNewline).first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(limit)) } ?? ""
        return line.isEmpty ? nil : line
    }
}

extension PiBridge {
    /// 这个会话能不能给自己起名（`SessionLink.canNameItself`）。
    public func canNameItself(_ id: PiSession.ID) -> Bool { controls[id]?.canNameItself(id) ?? false }

    /// 请会话按它的第一句话给自己起名并写回（`SessionNameSuggestion`）：还没有第一句话、这家起不了（抛 `unsupported`）、
    /// 起不出（超时、出错、空回答）都抛错。
    public func nameItself(_ id: PiSession.ID) async throws {
        guard let link = controls[id], let first = session(id: id)?.firstMessage else { throw PiBridgeError.unknownSession(id) }
        try await link.nameItself(from: PiSessionName.display(name: nil, firstMessage: first, folder: ""), in: id)
    }
}
#endif
