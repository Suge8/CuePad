import Foundation

/// 一条批注：你在 Agent 某条回答里选中的一段（`quote`）和你对它说的话（`note`，一定有字），随回复框里的下一句一起发出
/// （`ComposerDraft.notes`，发出时排成 `message(_:)`）。
/// 位置记在渲染后的文字里：哪条回答（`entry`，消息 id）、第几段可选文字（`run`，`MarkdownText.proseTexts` 的下标）、段内 UTF-16 偏移。
/// 回答写完后文字不再变，偏移是确切的，同一句话出现两次也不会挂错；那一处已不是 `quote` 时（渲染规则改了）只是不画高亮，发出时照样带摘录。
nonisolated struct ReplyNote: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    let entry: UUID
    let run: Int
    let location: Int
    let quote: String
    var note = ""

    var range: NSRange { NSRange(location: location, length: quote.utf16.count) }

    /// 正在写的一条（`AppSettings.editReplyNote`）：`fresh` 是还没进草稿的新的一条，记下时才排进去。
    struct Edit: Equatable, Identifiable, Sendable {
        var note: ReplyNote
        let fresh: Bool
        var id: UUID { note.id }
    }

    /// 同一处（同一条回答、同一段、同样的选区）。
    func marksSamePlace(as other: ReplyNote) -> Bool {
        entry == other.entry && run == other.run && location == other.location && quote == other.quote
    }

    /// 高亮上挂的链接：点高亮打开这条批注（`id(of:)` 认回来）。
    var url: URL { URL(string: "\(Self.scheme):\(id.uuidString)")! }

    static func id(of url: URL) -> UUID? {
        url.scheme == scheme ? UUID(uuidString: String(url.absoluteString.dropFirst(scheme.count + 1))) : nil
    }

    private static let scheme = "cuepad-note"

    /// 按在对话里的先后排（`order` 是对话里回答的 id 顺序）：Agent 读到的顺序就是原文的顺序，不是批注的先后。
    static func sorted(_ notes: [ReplyNote], by order: [UUID]) -> [ReplyNote] {
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return notes.sorted { (index[$0.entry] ?? .max, $0.run, $0.location) < (index[$1.entry] ?? .max, $1.run, $1.location) }
    }

    /// 发给 Agent 的那一段。原文已经在 Agent 自己的上下文里，所以不重发原文，只给能认出位置的摘录（`excerpt`）：
    /// 一条批注的定位只占二十来个 token，选得再长也一样。不用 Markdown 引用块（每行一个前缀）、不给行号（Agent 看不到行号）。
    static func message(_ notes: [ReplyNote]) -> String {
        guard !notes.isEmpty else { return "" }
        let lines = notes.enumerated().map { index, note in
            let said = note.note.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (notes.count > 1 ? "\(index + 1)." : "") + "「\(excerpt(note.quote))」" + said
        }
        return (["对你回答的批注（「」里是原话摘录）："] + lines).joined(separator: "\n")
    }

    /// 摘录：去掉渲染时加的列表符、引用竖条与缩进，空白收成一个空格；超过 `excerptLimit` 个字只留头尾各 `excerptEnd` 个字。
    static func excerpt(_ quote: String) -> String {
        let flat = quote.split { $0.isWhitespace || renderedMarks.contains($0) }.joined(separator: " ")
        guard flat.count > excerptLimit else { return flat }
        return "\(flat.prefix(excerptEnd))…\(flat.suffix(excerptEnd))"
    }

    static let excerptLimit = 30, excerptEnd = 12
    /// `MarkdownText` 排版时自己加的字符（列表符、次级列表符、引用竖条），不是 Agent 写的。
    private static let renderedMarks: Set<Character> = ["•", "◦", "▎"]
}
