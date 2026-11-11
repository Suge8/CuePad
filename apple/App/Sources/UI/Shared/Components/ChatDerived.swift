import CueStore
import SwiftUI

/// 滚动开始与结束、"回到最新"圆钮出现与消失都会让 `SessionChat` 重算 body，而这时对话数据没变：几百条的条目不用每次都推一遍。
final class ChatDerived {
    private struct Key: Equatable {
        let messages: [ChatMessage]
        let previews: [PreviewItem]
        let cueSent: Set<UUID>
        let deliveries: [DeliveryRequest]
        /// 没送到的话到点就换位置（`Chat.entries`）；此刻只在到点与同步通断时变（`SpeechClock`）。
        let moment: Speech.Moment
    }

    private var key: Key?
    private(set) var items: [ChatEntry] = []
    private(set) var marks: [ChatMark] = []

    func refresh(_ digest: SessionDigest, at moment: Speech.Moment) {
        let key = Key(messages: digest.messages, previews: digest.previews, cueSent: digest.cueSent, deliveries: digest.deliveries, moment: moment)
        guard key != self.key else { return }
        self.key = key
        items = Chat.entries(digest.messages, previews: digest.previews, deliveries: digest.deliveries, cueSent: key.cueSent, at: moment)
        marks = ChatScrubber.marks(items)
    }
}
