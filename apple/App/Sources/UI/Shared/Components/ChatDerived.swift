import CueStore
import SwiftUI

final class ChatDerived {
    struct Facts: Equatable {
        var items: [ChatEntry] = []
        var marks: [ChatMark] = []
        var trips: [Speech.Trip] = []
        var sending = false
        var lastSaid: String?
    }

    private struct Key: Equatable {
        let messages: [ChatMessage]
        let previews: [PreviewItem]
        let cueSent: Set<UUID>
        let deliveries: [DeliveryRequest]
        let moment: Speech.Moment
    }

    private var key: Key?
    private var facts = Facts()

    func refresh(_ digest: SessionDigest?, at moment: Speech.Moment) -> Facts {
        guard let digest else { return Facts() }
        let key = Key(messages: digest.messages, previews: digest.previews, cueSent: digest.cueSent, deliveries: digest.deliveries, moment: moment)
        guard key != self.key else { return facts }
        self.key = key
        let items = Chat.entries(digest.messages, previews: digest.previews, deliveries: digest.deliveries, cueSent: key.cueSent, at: moment)
        let trips = Chat.outgoing(digest.deliveries, messages: digest.messages).map { Speech.trip($0, at: moment) }
        facts = Facts(items: items, marks: ChatMark.of(items), trips: trips, sending: trips.contains(where: \.inTransit), lastSaid: Chat.lastSaid(digest.messages))
        return facts
    }
}
