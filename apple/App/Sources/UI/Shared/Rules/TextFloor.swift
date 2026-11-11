import CoreText
import Foundation

/// 一段字排在一栏里至少多高（Cue 页打开时按它数铺满一屏要排几格，`CuePage.paging`）：只能数少、不能数多，数多了第一帧铺不满。
/// 字按最小的那一号量（iOS 是动态字体最小的一档）：每行不折时排开多宽由 CoreText 量（中文回退到苹方，与排出来的同一套字形），
/// 折成几行至少是排开的宽除以一行的宽、往上取整（折行只会多出行；行尾的空格可以越过行宽，每行多给一个字宽）。
/// 排开的宽与栏宽无关，按原文记一份：窗口变宽、往上翻再数一遍时不再量。
enum TextFloor {
    enum Line {
        case prose(CGFloat)
        case code(CGFloat)
        case block(CGFloat)
    }

    static func markdown(_ source: String, width: CGFloat, spacing: CGFloat) -> CGFloat {
        height(lines(source, markdown: true), width: width, spacing: spacing, limit: nil)
    }

    static func plain(_ text: String, width: CGFloat, limit: Int?) -> CGFloat {
        height(lines(text, markdown: false), width: width, spacing: 0, limit: limit)
    }

    private static func height(_ lines: [Line], width: CGFloat, spacing: CGFloat, limit: Int?) -> CGFloat {
        var heights: [CGFloat] = []
        for line in lines {
            switch line {
            case .prose(let run): heights += repeatElement(Font.prose.line, count: Font.prose.wraps(run, in: width))
            case .code(let run): heights += repeatElement(Font.code.line, count: Font.code.wraps(run, in: width))
            case .block(let height): heights.append(height)
            }
        }
        let shown = heights.prefix(limit ?? heights.count)
        guard !shown.isEmpty else { return Font.code.line }
        return shown.reduce(0, +) + CGFloat(shown.count - 1) * spacing
    }

    private final class Lines {
        let lines: [Line]
        init(_ lines: [Line]) { self.lines = lines }
    }

    private static let measured = NSCache<NSString, Lines>()

    private static func lines(_ source: String, markdown: Bool) -> [Line] {
        let key = ((markdown ? "m" : "p") + source) as NSString
        if let cached = measured.object(forKey: key) { return cached.lines }
        let lines = markdown ? markdownLines(source) : source.split(separator: "\n", omittingEmptySubsequences: false).map { .prose(Font.prose.width(of: String($0))) }
        measured.setObject(Lines(lines), forKey: key)
        return lines
    }

    /// 段距（块与块之间的空行，`MarkdownText.attributed`）不算：它比一行矮。
    private static func markdownLines(_ source: String) -> [Line] {
        func prose(_ text: String, lead: String = "") -> [Line] {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { .prose(Font.prose.width(of: lead + MarkdownBlock.plainInline(String($0)))) }
        }
        return MarkdownBlock.parse(source).flatMap { block -> [Line] in
            switch block.content {
            case .paragraph(let text), .heading(_, let text): prose(text, lead: block.textIndent)
            case .quote(let text): prose(text, lead: block.textIndent + "▎ ")
            case .code(let code): code.split(separator: "\n", omittingEmptySubsequences: false).map { .code(Font.code.width(of: block.textIndent + String($0))) }
            // 一行至少上下各 8 的内边距加一行小字（`MarkdownTableView`）
            case .table(let table): [.block(CGFloat(table.rows.count + 1) * (16 + Font.code.size))]
            case .rule: [.prose(0)]
            }
        }
    }

    private struct Font {
        let font: CTFont
        let size: CGFloat
        let line: CGFloat

        init(size: CGFloat, monospaced: Bool) {
            let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
            font = monospaced ? CTFontCreateCopyWithSymbolicTraits(system, size, nil, .traitMonoSpace, .traitMonoSpace) ?? system : system
            self.size = size
            line = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.down)
        }

        func width(of text: String) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        func wraps(_ run: CGFloat, in width: CGFloat) -> Int { max(1, Int((run / (width + size)).rounded(.up))) }

        // 正文 `Typography.reading` 与代码 `Typography.code` 的最小号（iOS：动态字体最小一档的正文与脚注）
        #if os(macOS)
        static let prose = Font(size: Typography.readingSize, monospaced: false), code = Font(size: Typography.codeSize, monospaced: true)
        #else
        static let prose = Font(size: 14, monospaced: false), code = Font(size: 12, monospaced: true)
        #endif
    }
}
