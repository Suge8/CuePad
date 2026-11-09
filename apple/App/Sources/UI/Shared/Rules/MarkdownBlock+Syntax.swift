import Foundation

nonisolated extension MarkdownBlock {
    static func openingFence(_ line: String) -> (mark: Character, count: Int)? {
        guard let mark = line.first, mark == "`" || mark == "~" else { return nil }
        let count = line.prefix { $0 == mark }.count
        guard count >= 3, mark != "`" || !line.dropFirst(count).contains("`") else { return nil }
        return (mark, count)
    }

    /// 只移除列表容器的缩进，代码自身的空白与制表符保留；跨过容器边界的制表符剩余部分还原为空格。
    static func removingIndent(_ count: Int, from line: String) -> String {
        var column = 0
        var rest = line[...]
        while column < count, let character = rest.first, character == " " || character == "\t" {
            column = character == "\t" ? (column / 4 + 1) * 4 : column + 1
            rest.removeFirst()
        }
        return String(repeating: " ", count: max(0, column - count)) + rest
    }

    static func indentation(_ line: String) -> Int {
        line.prefix(while: \.isWhitespace).reduce(0) { $1 == "\t" ? ($0 / 4 + 1) * 4 : $0 + 1 }
    }

    /// 标题：1～6 个 `#`、空白、正文。
    static func heading(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first?.isWhitespace == true else { return nil }
        var text = rest.drop { $0.isWhitespace }
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0, text.dropLast(closing).last?.isWhitespace == true {
            text = Substring(text.dropLast(closing).trimmingCharacters(in: .whitespaces))
        }
        return text.isEmpty ? nil : (level, String(text))
    }

    /// 列表项：缩进、记号（`-`、`*`、`+`，或数字加 `.`、`)`）、空白、正文；无序的记号显示成"•"。
    static func item(_ raw: String) -> (marker: String, text: String, contentIndent: Int)? {
        let indent = raw.prefix { $0.isWhitespace }
        let rest = raw.dropFirst(indent.count)
        guard let first = rest.first else { return nil }
        let marker: Substring
        if "-*+".contains(first) {
            marker = rest.prefix(1)
        } else {
            let digits = rest.prefix { $0.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal } }
            guard !digits.isEmpty, let end = rest.dropFirst(digits.count).first, end == "." || end == ")" else { return nil }
            marker = rest.prefix(digits.count + 1)
        }
        let gap = rest.dropFirst(marker.count).prefix { $0.isWhitespace }
        guard !gap.isEmpty else { return nil }
        var text = rest.dropFirst(marker.count + gap.count)
        var shown = "-*+".contains(first) ? "•" : String(marker)
        if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            shown = text.hasPrefix("[ ]") ? "☐" : "☑"
            text = text.dropFirst(4)
        }
        guard !text.isEmpty else { return nil }
        return (shown, String(text), indentation(raw) + marker.count + gap.count)
    }
}
