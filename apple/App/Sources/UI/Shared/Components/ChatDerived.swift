import CueStore
import SwiftUI

/// 从对话数据推出来的东西：对话里的每一条（`PiChat.entries`）与刻度滑条的刻度。滚动开始与结束、"回到最新"圆钮出现与消失都会让 `SessionChat` 重算 body，
/// 而这时对话数据没变：几百条的条目不用每次都推一遍。
final class ChatDerived {
    private struct Key: Equatable {
        let messages: [PiChatMessage]
        let previews: [PiPreview]
        let cueSent: Set<UUID>
    }

    private var key: Key?
    private(set) var items: [PiChatEntry] = []
    private(set) var marks: [ChatMark] = []

    func refresh(_ digest: SessionDigest) {
        let key = Key(messages: digest.messages, previews: digest.previews, cueSent: digest.cueSent)
        guard key != self.key else { return }
        self.key = key
        items = PiChat.entries(digest.messages, previews: digest.previews, cueSent: key.cueSent)
        marks = ChatScrubber.marks(items)
    }
}
