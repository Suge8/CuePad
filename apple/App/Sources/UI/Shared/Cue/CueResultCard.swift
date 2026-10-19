import CueStore
import SwiftUI

/// 结果卡：挂着交付物的 Cue 的话（哪句挂哪几份只在 `CueThread.rows` 定）。一张纸，上面是那句话（Cue 做完时是"「X」做完了"与证据），
/// 中间是交付物（`DeliverableStrip`），末行是这件活（点开任务）。自成一行，不进气泡：靠左、最宽与 Cue 的气泡同一栏比例，
/// 字与气泡里的字、旁注的图标对齐（`CueBubble.padding`）；点一份放大到全屏，底栏是关于它对 Cue 说。
/// 那句话的第一行是一句平常的话时（"「X」做完了"）单独加粗作标题，其余照 Markdown：一眼先读到做完了什么，再看证据。
struct CueResultCard: View {
    let message: CueMessage
    let ref: CueTaskRef
    let deliverables: [PiPreview]
    let open: (PreviewOpening) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let parts = Self.headline(message.text)
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let title = parts.title {
                        Text(Self.inline(title)).font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink)
                            .lineSpacing(Typography.readingLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !parts.body.isEmpty { MarkdownText(source: parts.body).equatable() }
                }
                .contextMenu { MessageActions(text: message.text, kind: .cue) }
                DeliverableStrip(previews: deliverables, size: .result, group: message.id.uuidString, bleed: CueBubble.padding.leading) {
                    open(PreviewOpening(preview: $0, batch: deliverables, group: message.id.uuidString, reply: .cue))
                }
                CueTaskLine(ref: ref)
            }
            .padding(CueBubble.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: CueBubble.radius)
        }
        .transition(CueBubble.arrival(.leading, reduceMotion: reduceMotion))
    }

    /// 第一行是平常的一句话（不是标题、列表、引用、代码、表格）时拆出来作标题，其余是正文。
    static func headline(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first.map(String.init), !first.isEmpty, !Self.isMarkup(first) else { return (nil, trimmed) }
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (first, rest)
    }

    /// 标题行里的行内记号（粗体、代码、链接）照样认，不露出星号与反引号。
    private static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }

    private static func isMarkup(_ line: String) -> Bool {
        if ["#", "-", "*", "+", ">", "`", "|", "!["].contains(where: line.hasPrefix) { return true }
        return line.prefix { $0.isNumber }.count > 0 && line.drop { $0.isNumber }.hasPrefix(".")
    }
}
