import Foundation

/// Pi 回答的 Markdown 块（iOS 会话页、Mac 会话详情共用）。只认回答里常见的几种，其余按段落；块内的行内语法
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

    /// 去掉 Markdown 符号的纯文字，一块一行（列表预览用：先去符号再截断）。行内的强调、代码、链接只留文字；表格取表头。
    static func plainLines(_ source: String) -> [String] {
        parse(source).compactMap { block in
            let text: String = switch block {
            case .paragraph(let text), .heading(_, let text), .item(_, let text, _), .quote(let text): plainInline(text)
            case .code(let text): text
            case .table(let table): table.header.map(plainInline).joined(separator: " · ")
            case .rule: ""
            }
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    private static func plainInline(_ text: String) -> String {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? text
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String]?
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            if let quote { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = nil
        }
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
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
                blocks.append(.table(MarkdownTable(alignments: alignments, header: header, rows: rows)))
            } else if line.wholeMatch(of: /(\*\s*){3,}|(-\s*){3,}|(_\s*){3,}/) != nil {
                flush()
                blocks.append(.rule)
            } else if let heading = line.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                flush()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
            } else if let item = raw.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.+)$/) {
                flush()
                let marker = item.2.first.map { "-*+".contains($0) } == true ? "•" : String(item.2)
                blocks.append(.item(marker: marker, text: String(item.3), depth: item.1.count / 2))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
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
        guard !cells.isEmpty, cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
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

