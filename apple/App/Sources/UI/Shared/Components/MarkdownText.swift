import SwiftUI

/// Pi 回答的 Markdown 渲染：按块解析（段落、标题、列表项、代码块），块内用系统的行内 Markdown（加粗、斜体、
/// 行内代码、链接）。列表保留缩进与序号，代码块等宽、可横向滚动；解析不了的照原文显示。
struct MarkdownText: View {
    let source: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text)).font(.body).foregroundStyle(palette.ink)
                case .heading(let text):
                    Text(Self.inline(text)).font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                case .item(let marker, let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(.body.monospacedDigit()).foregroundStyle(palette.ink3)
                        Text(Self.inline(text)).font(.body).foregroundStyle(palette.ink)
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).font(.footnote.monospaced()).foregroundStyle(palette.ink).padding(10)
                    }
                    .background(palette.fill, in: .rect(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Markdown 的块。只认回答里常见的几种，其余按段落。
nonisolated enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    /// 列表项：显示用的标记（"•" 或 "1."）、正文、缩进层级。
    case item(marker: String, text: String, depth: Int)
    case code(String)

    /// 去掉 Markdown 符号的纯文字，一块一行（列表预览用：先去符号再截断）。行内的强调、代码、链接只留文字。
    static func plainLines(_ source: String) -> [String] {
        parse(source).compactMap { block in
            let text: String = switch block {
            case .paragraph(let text), .heading(let text), .item(_, let text, _): plainInline(text)
            case .code(let text): text
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
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
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
            if line.isEmpty { flush(); continue }
            if let heading = line.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                flush()
                blocks.append(.heading(String(heading.1)))
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
