import CueStore
import SwiftUI

final class ChatDerived {
    private struct Key: Equatable {
        let messages: [ChatMessage]
        let previews: [PreviewItem]
        let cueSent: Set<UUID>
        let deliveries: [DeliveryRequest]
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
        marks = ChatMark.of(items)
    }
}
