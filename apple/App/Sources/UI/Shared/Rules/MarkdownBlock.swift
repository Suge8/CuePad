import CueText
import Foundation

/// 每个块都携带同一份列表路径；块类型不决定归属。路径末项是直接父项，startsItem 只标记该项的首块。
nonisolated struct MarkdownBlock: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case paragraph(String), heading(level: Int, text: String), quote(String), code(String), table(MarkdownTable), rule
    }
    struct ListItem: Equatable, Sendable {
        let marker: String
        let contentIndent: Int
    }
    let content: Content
    var list: [ListItem] = []
    var startsItem = false
    var isList: Bool { !list.isEmpty }
    var depth: Int { max(0, list.count - 1) }
    var textIndent: String {
        guard let item = list.last else { return "" }
        return String(repeating: "\u{2003}\u{2003}", count: depth) + (startsItem ? item.marker : String(repeating: " ", count: item.marker.count)) + "\u{2002}"
    }

    static func firstPlainLine(_ source: String) -> String? {
        var line: String?, table = false, code = false
        _ = parse(source) { block in
            switch block.content {
            case .paragraph(let text), .heading(_, let text), .quote(let text):
                line = text.split(whereSeparator: \.isNewline).lazy.map { plainInline(String($0)).trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            case .table: table = true
            case .code: code = true
            case .rule: break
            }
            return line == nil
        }
        return line ?? (table ? String(localized: "（一张表格）") : code ? String(localized: "（一段代码）") : nil)
    }

    static func plainInline(_ text: String) -> String {
        guard text.contains(where: inlineMarks.contains) else { return text }
        return String(AttributedString(inlineMarkdown: text).characters)
    }
    private static let inlineMarks: Set<Character> = ["*", "_", "`", "[", "]", "\\", "<", "&", "~", "!"]

    static func plainText(_ source: String) -> String {
        parse(source).map { block in
            switch block.content {
            case .paragraph(let text), .heading(_, let text): plainInline(text)
            case .quote(let text): plainText(text)
            case .code(let text): text
            case .table(let table): ([table.header] + table.rows).map { $0.map(plainInline).joined(separator: " ") }.joined(separator: "\n")
            case .rule: ""
            }
        }.joined(separator: "\n")
    }
}
