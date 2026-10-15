import SwiftUI

/// 分段的长文字（回答、你说的话、带上的卡片全文）：按换行分段，iOS 上一段一个 `Text`，Mac 上整串一个。
/// iOS 的 `Text` 排一次版的耗时随段数乘全串长度增长：iPhone 17 模拟器上 8000 字 176 段的一个 `Text` 排一次 1.7 秒，同样的字逐段排 34 毫秒，
/// 一段 8000 字也只要 26 毫秒；一条长回答整串一个 `Text` 时，会话页一打开就把主线程占住好几秒，宽度每变一次（推入转场里就有几次）再排一遍。
/// Mac 的排版与段数无关（同一条 8000 字 6 毫秒），整串一个 `Text`，一条回答、一颗气泡里能跨段拖选。
/// 分开排与整串排一样高：段与段之间隔的就是行距；空段（Markdown 的段距行、空行）是一个带着那个换行字体的空格。
struct Paragraphs: View {
    let text: AttributedString
    var lineSpacing: CGFloat = 0
    /// 最多排几行（折起的气泡）。
    var lineLimit: Int?

    init(_ text: AttributedString, lineSpacing: CGFloat = 0, lineLimit: Int? = nil) {
        self.text = text
        self.lineSpacing = lineSpacing
        self.lineLimit = lineLimit
    }

    init(verbatim text: String, lineLimit: Int? = nil) {
        self.init(AttributedString(text), lineLimit: lineLimit)
    }

    var body: some View {
        #if os(macOS)
        Text(text).lineSpacing(lineSpacing).lineLimit(lineLimit).selectable()
        #else
        if let lineLimit {
            // 前几行一定在前几段里：只排前这么多段
            Text(Self.prefix(text, paragraphs: lineLimit)).lineSpacing(lineSpacing).lineLimit(lineLimit).selectable()
        } else {
            VStack(alignment: .leading, spacing: lineSpacing) {
                ForEach(Array(Self.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).lineSpacing(lineSpacing).selectable()
                }
            }
            // 读屏照旧把整串当一段读
            .accessibilityElement(children: .combine)
        }
        #endif
    }

    #if os(iOS)
    private static func paragraphs(_ text: AttributedString) -> [AttributedString] {
        let characters = text.characters
        var result: [AttributedString] = []
        var start = text.startIndex
        for index in characters.indices where characters[index].isNewline {
            let next = characters.index(after: index)
            result.append(start == index
                ? AttributedString(" ", attributes: text[index..<next].runs.first?.attributes ?? AttributeContainer())
                : AttributedString(text[start..<index]))
            start = next
        }
        if start < text.endIndex { result.append(AttributedString(text[start...])) }
        return result
    }

    /// 前 `count` 段（到第 `count` 个换行为止）。
    private static func prefix(_ text: AttributedString, paragraphs count: Int) -> AttributedString {
        let characters = text.characters
        var seen = 0
        for index in characters.indices where characters[index].isNewline {
            seen += 1
            if seen == count { return AttributedString(text[..<index]) }
        }
        return text
    }
    #endif
}
