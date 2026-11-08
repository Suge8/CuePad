#if DEBUG
import CueStore
import Foundation

extension DebugScene {
    static var notesPreviewReply: String {
        String(localized: "发给你了：完整页面可以直接点按钮试交互，截图是 iPhone 宽度下的样子，评审结论里有两处要你定。", table: "Demo")
    }

    /// 摘录的独立译文可能大写开头；位置和最终摘录都取回答本身，保持生产高亮的精确匹配。
    static func demoReplyNote(entry: UUID, quote: String, note: String) -> ReplyNote {
        let source = notesPreviewReply
        guard let range = source.range(of: quote, options: .caseInsensitive) else {
            preconditionFailure("演示批注必须来自本地化后的回答")
        }
        return ReplyNote(entry: entry, run: 0, location: NSRange(range, in: source).location, quote: String(source[range]), note: note)
    }
}
#endif
