import CueText
import Foundation

nonisolated extension MarkdownBlock {
    /// 列表只在遇到非空行时按缩进收栈；任何块都从这一份栈取路径，不在块分支里清空或另建归属。
    static func parse(_ source: String, more: (MarkdownBlock) -> Bool = { _ in true }) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var list: [ListItem] = []
        var pending: MarkdownBlock?
        var fence: (mark: Character, count: Int)?
        var done = false
        func add(_ block: MarkdownBlock) {
            guard !done else { return }
            blocks.append(block)
            done = !more(block)
        }
        func flush() {
            if let pending { add(pending) }
            pending = nil
        }
        var index = 0
        while index < lines.count, !done {
            let raw = lines[index]
            var line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if let opening = fence, let block = pending, case .code(let text) = block.content {
                let count = line.prefix { $0 == opening.mark }.count
                if count >= opening.count, line.dropFirst(count).allSatisfy(\.isWhitespace) {
                    flush()
                    fence = nil
                } else {
                    let codeLine = removingIndent(block.list.last?.contentIndent ?? 0, from: raw)
                    pending = MarkdownBlock(content: .code(text + codeLine + "\n"), list: block.list, startsItem: block.startsItem)
                }
                continue
            }
            if line.isEmpty { flush(); continue }
            let indent = indentation(raw)
            let newItem = CueFormat.isRule(line) ? nil : item(raw)
            while let parent = list.last, indent < parent.contentIndent { list.removeLast() }
            var startsItem = false
            if let newItem {
                flush()
                list.append(ListItem(marker: newItem.marker, contentIndent: newItem.contentIndent))
                line = newItem.text
                startsItem = true
            }
            if let block = pending, block.list != list { flush() }
            if let opening = openingFence(line) {
                flush()
                fence = opening
                pending = MarkdownBlock(content: .code(""), list: list, startsItem: startsItem)
                continue
            }
            if line.hasPrefix(">") {
                let text = String(line.dropFirst().drop { $0 == " " })
                if let block = pending, case .quote(let previous) = block.content {
                    pending = MarkdownBlock(content: .quote(previous + "\n" + text), list: list, startsItem: block.startsItem)
                } else {
                    flush()
                    pending = MarkdownBlock(content: .quote(text), list: list, startsItem: startsItem)
                }
                continue
            }
            if let block = pending, case .quote(let text) = block.content {
                let tableStarts = line.contains("|") && index < lines.count && MarkdownTable.alignments(lines[index]) != nil
                if !startsItem, heading(line) == nil, !CueFormat.isRule(line), !tableStarts {
                    pending = MarkdownBlock(content: .quote(text + "\n" + line), list: list, startsItem: block.startsItem)
                    continue
                }
                flush()
            }
            if line.contains("|"), index < lines.count, indentation(lines[index]) >= (list.last?.contentIndent ?? 0), let alignments = MarkdownTable.alignments(lines[index]),
               case let header = MarkdownTable.cells(line), header.count == alignments.count {
                flush()
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index]
                    guard indentation(row) >= (list.last?.contentIndent ?? 0), !row.trimmingCharacters(in: .whitespaces).isEmpty,
                          row.contains("|"), item(row) == nil else { break }
                    let cells = MarkdownTable.cells(row)
                    rows.append(Array(cells.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - cells.count)))
                    index += 1
                }
                add(MarkdownBlock(content: .table(MarkdownTable(alignments: alignments, header: header, rows: rows)), list: list, startsItem: startsItem))
            } else if let block = pending, case .paragraph(let text) = block.content,
                      line.allSatisfy({ $0 == "=" }) || line.allSatisfy({ $0 == "-" }) {
                pending = nil
                add(MarkdownBlock(content: .heading(level: line.first == "=" ? 1 : 2, text: text), list: list, startsItem: block.startsItem))
            } else if CueFormat.isRule(line) {
                flush()
                add(MarkdownBlock(content: .rule, list: list, startsItem: startsItem))
            } else if let heading = heading(line) {
                flush()
                add(MarkdownBlock(content: .heading(level: heading.level, text: heading.text), list: list, startsItem: startsItem))
            } else if let block = pending, case .paragraph(let text) = block.content {
                pending = MarkdownBlock(content: .paragraph(text + "\n" + line), list: list, startsItem: block.startsItem)
            } else {
                pending = MarkdownBlock(content: .paragraph(line), list: list, startsItem: startsItem)
            }
        }
        if !done { flush() }
        // 围栏正文以换行累积，去掉最后一个行分隔，保留原文真正的空行。
        return blocks.map { block in
            guard case .code(let text) = block.content, text.hasSuffix("\n") else { return block }
            return MarkdownBlock(content: .code(String(text.dropLast())), list: block.list, startsItem: block.startsItem)
        }
    }
}
