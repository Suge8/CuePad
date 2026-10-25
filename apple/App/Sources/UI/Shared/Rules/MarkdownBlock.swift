import Foundation

/// Pi 回答的 Markdown 块（iOS 会话页、Mac 会话页共用）。只认回答里常见的几种，其余按段落；块内的行内语法
/// （加粗、斜体、行内代码、链接）原样留在文字里，由渲染时交给系统的行内 Markdown。
nonisolated enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// 列表项：显示用的标记（"•" 或 "1."）、正文、缩进层级。
    case item(marker: String, text: String, depth: Int)
    case quote(String)
    case code(String)
    case table(MarkdownTable)
    case rule

    /// 摘要用的第一行文字（列表预览：先去符号再截断）：第一个文字块（段落、标题、列表项、引用）的第一行，行内的强调、代码、链接只留文字；
    /// 表格与代码块跳过，整段只有它们时说它是什么。找到就不往下拆（摘要的原文常是整篇长回答）。
    static func firstPlainLine(_ source: String) -> String? {
        var line: String?, table = false, code = false
        _ = parse(source) { block in
            switch block {
            case .paragraph(let text), .heading(_, let text), .item(_, let text, _), .quote(let text):
                line = text.split(whereSeparator: \.isNewline).lazy
                    .map { plainInline(String($0)).trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            case .table: table = true
            case .code: code = true
            case .rule: break
            }
            return line == nil
        }
        return line ?? (table ? String(localized: "（一张表格）") : code ? String(localized: "（一段代码）") : nil)
    }

    /// 一行里的行内记号（强调、代码、链接、转义、实体）只留显示的字；没有这些记号的行原样（系统的行内解析每行要建一份带属性的文字）。
    static func plainInline(_ text: String) -> String {
        guard text.contains(where: inlineMarks.contains) else { return text }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? text
    }

    private static let inlineMarks: Set<Character> = ["*", "_", "`", "[", "]", "\\", "<", "&", "~", "!"]

    /// 拆块；`more` 每拆出一块问一次还要不要往下拆（摘要找到第一行就停）。
    static func parse(_ source: String, more: (MarkdownBlock) -> Bool = { _ in true }) -> [MarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String]?
        var code: [String]?
        var done = false
        // 停下之后同一行里还会再收（先收起前面的段落、引用，再收这一行的块）：都不要，摘要拿到的才是第一块
        func add(_ block: MarkdownBlock) {
            guard !done else { return }
            blocks.append(block)
            if !more(block) { done = true }
        }
        func flush() {
            if !paragraph.isEmpty { add(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            if let quote { add(.quote(quote.joined(separator: "\n"))) }
            quote = nil
        }
        var index = 0
        while index < lines.count, !done {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("```") {
                if let lines = code {
                    add(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix(">") {
                if quote == nil { flush(); quote = [] }
                quote?.append(String(line.dropFirst().drop { $0 == " " }))
                continue
            }
            if quote != nil { flush() }
            if line.isEmpty { flush(); continue }
            // 表格：一行竖线、下一行是同样列数的对齐行；之后带竖线的行都是表体
            if line.contains("|"), index < lines.count, let alignments = MarkdownTable.alignments(lines[index]),
               case let header = MarkdownTable.cells(line), header.count == alignments.count {
                flush()
                index += 1
                var rows: [[String]] = []
                while index < lines.count, case let row = lines[index].trimmingCharacters(in: .whitespaces), !row.isEmpty, row.contains("|") {
                    let cells = MarkdownTable.cells(row)
                    rows.append(Array(cells.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - cells.count)))
                    index += 1
                }
                add(.table(MarkdownTable(alignments: alignments, header: header, rows: rows)))
            } else if Self.isRule(line) {
                flush()
                add(.rule)
            } else if let heading = Self.heading(line) {
                flush()
                add(.heading(level: heading.level, text: heading.text))
            } else if let item = Self.item(raw) {
                flush()
                add(.item(marker: item.marker, text: item.text, depth: item.depth))
            } else {
                paragraph.append(line)
            }
        }
        if !done, let lines = code { add(.code(lines.joined(separator: "\n"))) }
        if !done { flush() }
        return blocks
    }

    // 逐行的几种块不用正则：正则字面量每求值一次就新建一份、第一次匹配时再编译，写在逐行的循环里时每行编译一遍
    // （长回答打开会话页时占了拆块的大半），存成静态的又不能跨线程共用。

    /// 分隔线：同一个记号（`*`、`-`、`_`）至少三个，中间可夹空白。
    private static func isRule(_ line: String) -> Bool {
        guard let mark = line.first, "*-_".contains(mark) else { return false }
        var count = 0
        for character in line where !character.isWhitespace {
            guard character == mark else { return false }
            count += 1
        }
        return count >= 3
    }

    /// 标题：1～6 个 `#`、空白、正文。
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first?.isWhitespace == true else { return nil }
        let text = rest.drop { $0.isWhitespace }
        return text.isEmpty ? nil : (level, String(text))
    }

    /// 列表项：缩进（每两格一层）、记号（`-`、`*`、`+`，或数字加 `.`、`)`）、空白、正文；无序的记号显示成"•"。
    private static func item(_ raw: String) -> (marker: String, text: String, depth: Int)? {
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
        let text = rest.dropFirst(marker.count + gap.count)
        guard !text.isEmpty else { return nil }
        return ("-*+".contains(first) ? "•" : String(marker), String(text), indent.count / 2)
    }
}

/// GFM 表格：每列的对齐、表头、表体（每行补齐或截到表头的列数）。单元格保留行内语法。
nonisolated struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    var alignments: [Alignment]
    var header: [String]
    var rows: [[String]]

    /// 对齐行（"|:---|---:|:-:|"）的每列对齐；不是对齐行时为 nil。
    static func alignments(_ line: String) -> [Alignment]? {
        let cells = cells(line)
        guard !cells.isEmpty, cells.allSatisfy(isAlignment) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    /// 一格对齐记号：可选的冒号、至少一个横线、可选的冒号。
    private static func isAlignment(_ cell: String) -> Bool {
        var marks = Substring(cell)
        if marks.first == ":" { marks = marks.dropFirst() }
        if marks.last == ":" { marks = marks.dropLast() }
        return !marks.isEmpty && marks.allSatisfy { $0 == "-" }
    }

    /// 一行拆成单元格：去掉首尾的竖线，按没转义的竖线分，"\|" 还原成竖线。
    static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        while let character = body.popFirst() {
            if character == "\\", body.first == "|" {
                cell.append("|")
                body.removeFirst()
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

