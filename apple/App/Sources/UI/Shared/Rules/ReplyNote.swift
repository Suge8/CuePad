import CueStore
import Foundation

/// 只在回复框的草稿里（本机偏好，`AppSettings`），随下一句发出，不入库。
/// 位置记在渲染后的文字里：回答写完后文字不再变，偏移是确切的，同一句话出现两次也不会挂错；那一处已不是 `quote` 时（渲染规则改了）只是不画高亮，发出时照样带摘录。
/// 引用一份预览时不碰文件，网页地址那类预览也一样引用；话就是回复框里你写的那句，自己没有字（`note` 空）。
nonisolated struct ReplyNote: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    let entry: UUID
    let run: Int
    let location: Int
    let quote: String
    var note = ""
    var preview: UUID?
    /// 没有它的旧草稿照常解出来（只是过期后是一张纸）。
    var kind: PiPreviewKind?

    init(entry: UUID, run: Int, location: Int, quote: String, note: String = "") {
        self.entry = entry
        self.run = run
        self.location = location
        self.quote = quote
        self.note = note
    }

    init(quoting preview: PiPreview, in entry: UUID) {
        self.init(entry: entry, run: 0, location: 0, quote: preview.title)
        self.preview = preview.id
        kind = preview.kind
    }

    /// 引用的那份预览，按编号从这个会话此刻的预览里取（`SessionDigest.previews`）：引用只记编号，画面显示时再取，
    /// 预览随对话过期删掉后取不到（nil），这一行仍照标题发出。
    func quoted(in previews: [PiPreview]) -> PiPreview? {
        preview.flatMap { id in previews.first { $0.id == id } }
    }

    var range: NSRange { NSRange(location: location, length: quote.utf16.count) }

    struct Edit: Equatable, Identifiable, Sendable {
        var note: ReplyNote
        let fresh: Bool
        var id: UUID { note.id }
    }

    func marksSamePlace(as other: ReplyNote) -> Bool {
        entry == other.entry && run == other.run && location == other.location && quote == other.quote && preview == other.preview
    }

    var url: URL { URL(string: "\(Self.scheme):\(id.uuidString)")! }

    static func id(of url: URL) -> UUID? {
        url.scheme == scheme ? UUID(uuidString: String(url.absoluteString.dropFirst(scheme.count + 1))) : nil
    }

    private static let scheme = "cuepad-note"

    /// 按在对话里的先后排（`order` 是对话里回答的 id 顺序）：Agent 读到的顺序就是原文的顺序，不是批注的先后。引用的预览不在里面，排在最后、按引用的先后。
    static func sorted(_ notes: [ReplyNote], by order: [UUID]) -> [ReplyNote] {
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let passages = notes.filter { $0.preview == nil }
            .sorted { (index[$0.entry] ?? .max, $0.run, $0.location) < (index[$1.entry] ?? .max, $1.run, $1.location) }
        return passages + notes.filter { $0.preview != nil }
    }

    /// 发给 Agent 的话：对回答的批注一段排在最前；原文已经在 Agent 自己的上下文里，所以不重发原文，只给能认出位置的摘录（`excerpt`）：
    /// 一条批注的定位只占二十来个 token，选得再长也一样。不用 Markdown 引用块（每行一个前缀）、不给行号（Agent 看不到行号）。
    /// 引用的预览写在你那句话前头：`预览「标题」：话`——标题是 Agent 发它时自己写的（`cuepad show --title`），它认得出是哪份。
    static func message(_ notes: [ReplyNote], said text: String) -> String {
        let passages = notes.filter { $0.preview == nil }
        let quoted = notes.filter { $0.preview != nil }.map { String(localized: "预览「\($0.quote)」") }.formatted(.list(type: .and))
        let said = quoted.isEmpty ? text : text.allSatisfy(\.isWhitespace) ? quoted : String(localized: "\(quoted)：\(text)")
        return [comments(passages), said].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func comments(_ notes: [ReplyNote]) -> String {
        guard !notes.isEmpty else { return "" }
        let lines = notes.enumerated().map { index, note in
            let said = note.note.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (notes.count > 1 ? "\(index + 1)." : "") + String(localized: "「\(excerpt(note.quote))」\(said)")
        }
        return ([String(localized: "对你回答的批注（「」里是原话摘录）：")] + lines).joined(separator: "\n")
    }

    static func excerpt(_ quote: String) -> String {
        let flat = quote.split { $0.isWhitespace || renderedMarks.contains($0) }.joined(separator: " ")
        guard flat.count > excerptLimit else { return flat }
        return "\(flat.prefix(excerptEnd))…\(flat.suffix(excerptEnd))"
    }

    static let excerptLimit = 30, excerptEnd = 12
    /// `MarkdownText` 排版时自己加的字符（列表符、次级列表符、引用竖条），不是 Agent 写的。
    private static let renderedMarks: Set<Character> = ["•", "◦", "▎"]
}
