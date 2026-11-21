import CueStore
import Foundation

nonisolated struct ReplyNote: Identifiable, Equatable, Codable, Sendable {
    struct Element: Equatable, Codable, Sendable {
        let page: String
        let selector: String
        let tag: String
        let text: String
        var component: String?
        var source: String?

        var title: String { text.isEmpty ? "<\(tag)>" : text }
    }

    var id = UUID()
    let entry: UUID
    let run: Int
    let location: Int
    let quote: String
    var note = ""
    var preview: UUID?
    var kind: PreviewKind?
    var element: Element?

    init(entry: UUID, run: Int, location: Int, quote: String, note: String = "") {
        self.entry = entry
        self.run = run
        self.location = location
        self.quote = quote
        self.note = note
    }

    init(quoting preview: PreviewItem, in entry: UUID) {
        self.init(entry: entry, run: 0, location: 0, quote: preview.title)
        self.preview = preview.id
        kind = preview.kind
    }

    init(picking element: Element) {
        self.init(entry: UUID(), run: 0, location: 0, quote: element.title)
        self.element = element
    }

    var marksPassage: Bool { preview == nil && element == nil }

    func quoted(in previews: [PreviewItem]) -> PreviewItem? {
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

    static func sorted(_ notes: [ReplyNote], by order: [UUID]) -> [ReplyNote] {
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let passages = notes.filter(\.marksPassage)
            .sorted { (index[$0.entry] ?? .max, $0.run, $0.location) < (index[$1.entry] ?? .max, $1.run, $1.location) }
        return passages + notes.filter { $0.element != nil } + notes.filter { $0.preview != nil }
    }

    static func message(_ notes: [ReplyNote], said text: String) -> String {
        let passages = notes.filter(\.marksPassage), previews = notes.filter { $0.preview != nil }
        let noted = previews.filter { !$0.note.isEmpty }.map { String(localized: "\(String(localized: "预览「\($0.quote)」"))：\($0.note)") }.joined(separator: "\n")
        let quoted = previews.filter(\.note.isEmpty).map { String(localized: "预览「\($0.quote)」") }.formatted(.list(type: .and))
        let said = quoted.isEmpty ? text : text.allSatisfy(\.isWhitespace) ? quoted : String(localized: "\(quoted)：\(text)")
        return [comments(passages), picked(notes.compactMap(\.element)), noted, said].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func picked(_ elements: [Element]) -> String {
        guard !elements.isEmpty else { return "" }
        let lines = elements.map { element in
            var parts = ["页面 \(element.page)", "选择器 \(element.selector)", "<\(element.tag)>" + (element.text.isEmpty ? "" : "「\(excerpt(element.text))」")]
            if let component = element.component { parts.append("组件 \(component)") }
            if let source = element.source { parts.append("源码 \(source)") }
            return "- " + parts.joined(separator: "，")
        }
        return (["我在活预览里点选的页面元素："] + lines).joined(separator: "\n")
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
    private static let renderedMarks: Set<Character> = ["•", "◦", "▎"]
}
