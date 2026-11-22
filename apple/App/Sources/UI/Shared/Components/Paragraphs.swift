import SwiftUI

/// iOS 的 `Text` 排一次版的耗时随段数乘全串长度增长：iPhone 17 模拟器上 8000 字 176 段的一个 `Text` 排一次 1.7 秒，同样的字逐段排 34 毫秒，
/// 一段 8000 字也只要 26 毫秒；一条长回答整串一个 `Text` 时，会话页一打开就把主线程占住好几秒，宽度每变一次（推入转场里就有几次）再排一遍。
/// Mac 的排版与段数无关（同一条 8000 字 6 毫秒），整串一个 `Text`，一条回答、一颗气泡里能跨段拖选。
/// 分开排与整串排一样高：段与段之间隔的就是行距；空段（Markdown 的段距行、空行）是一个带着那个换行字体的空格。
/// 出字时（`reveal`，这段文字的起点在整段话里的位置）只排到出字到的那一段为止，那一段整段排好、没出到的字不画：
/// 段在出字时不再重排（iOS 的 `Text` 排一段时整段权衡断点，段长一个字前面几行的断点就跟着变），高度一段一段长。
struct Paragraphs: View {
    let text: AttributedString
    @ScaledMetric private var lineSpacing: CGFloat
    var lineLimit: Int?
    var reveal: (frame: RevealFrame, offset: Int)?
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale

    init(_ text: AttributedString, lineSpacing: CGFloat = 0, lineLimit: Int? = nil, reveal: (frame: RevealFrame, offset: Int)? = nil) {
        self.text = text
        _lineSpacing = ScaledMetric(wrappedValue: lineSpacing, relativeTo: .body)
        self.lineLimit = lineLimit
        self.reveal = reveal
    }

    init(verbatim text: String, lineSpacing: CGFloat = 0, lineLimit: Int? = nil) {
        self.init(AttributedString(text), lineSpacing: lineSpacing, lineLimit: lineLimit)
    }

    var body: some View {
        if let lineLimit {
            Text(Self.prefix(text, paragraphs: lineLimit)).lineSpacing(lineSpacing).lineLimit(lineLimit).selectable()
        } else if let reveal {
            revealed(reveal.frame, from: reveal.offset)
        } else {
            #if os(macOS)
            Text(text).lineSpacing(lineSpacing).selectable()
            #else
            VStack(alignment: .leading, spacing: lineSpacing) {
                ForEach(Array(Self.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).lineSpacing(lineSpacing).selectable()
                }
            }
            .accessibilityElement(children: .combine)
            #endif
        }
    }

    @ViewBuilder private func revealed(_ frame: RevealFrame, from offset: Int) -> some View {
        let starts = Self.starts(text).map { offset + $0 }, head = frame.head
        let shown = max(1, starts.prefix { Double($0) < head }.count)
        let end = (shown < starts.count ? starts[shown] - 1 : offset + text.characters.reduce(0) { $0 + $1.utf16.count })
        #if os(macOS)
        Text(Self.prefix(text, paragraphs: shown)).lineSpacing(lineSpacing).selectable().textRenderer(renderer(frame, starts.prefix(shown), end: end))
        #else
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(Self.paragraphs(text).prefix(shown).enumerated()), id: \.offset) { index, paragraph in
                Text(paragraph).lineSpacing(lineSpacing).selectable()
                    .textRenderer(renderer(frame, starts[index...index], end: index + 1 < shown ? starts[index + 1] - 1 : end))
            }
        }
        .accessibilityElement(children: .combine)
        #endif
    }

    private func renderer(_ frame: RevealFrame, _ starts: ArraySlice<Int>, end: Int) -> RevealRenderer {
        RevealRenderer(frame: frame, starts: Array(starts), end: end, cell: DitherGPU.cell * 2 / scale, hot: palette.thinkingHigh, warm: palette.thinkingMid)
    }

    /// 每段的起点（UTF-16）：段与段之间隔一个换行。
    private static func starts(_ text: AttributedString) -> [Int] {
        var starts = [0], at = 0
        for character in text.characters {
            at += character.utf16.count
            if character.isNewline { starts.append(at) }
        }
        return starts
    }

    #if os(iOS)
    private static func paragraphs(_ text: AttributedString) -> [AttributedString] {
        let characters = text.characters
        var result: [AttributedString] = []
        var start = text.startIndex
        for index in characters.indices where characters[index].isNewline {
            let next = characters.index(after: index)
            result.append(start == index
                ? AttributedString(" ", attributes: text[index..<next].runs.first!.attributes)
                : AttributedString(text[start..<index]))
            start = next
        }
        if start < text.endIndex { result.append(AttributedString(text[start...])) }
        return result
    }
    #endif

    private static func prefix(_ text: AttributedString, paragraphs count: Int) -> AttributedString {
        let characters = text.characters
        var seen = 0
        for index in characters.indices where characters[index].isNewline {
            seen += 1
            if seen == count { return AttributedString(text[..<index]) }
        }
        return text
    }
}
