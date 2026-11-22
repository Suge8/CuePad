import Foundation

nonisolated extension CueNow {
    struct Decay: Codable, Hashable, Sendable {
        var at: Date
        var tally: Tally
        var advancing: Int
        var subagents: Int
        var items: [Change]
        var first: Wait?
        var replaceFirst: Bool
        var agentCount: Int? = nil

        enum CodingKeys: String, CodingKey { case at = "t", tally = "c", advancing = "a", subagents = "s", items = "i", first = "f", replaceFirst = "r", agentCount = "g" }

        enum Change: Codable, Hashable, Sendable {
            case update(slot: Int, kind: Item.Kind, since: Date, subagents: Int)
            case replace(Item)
            case remove(slot: Int)
        }
    }

    mutating func apply(_ step: Decay) {
        tally = step.tally
        advancing = step.advancing
        subagents = step.subagents
        agentCount = step.agentCount
        unconfirmed = true
        for change in step.items {
            switch change {
            case .update(let slot, let kind, let since, let subagents):
                if let index = items.firstIndex(where: { $0.slot == slot }) {
                    items[index].kind = kind
                    items[index].since = since
                    items[index].subagents = subagents
                }
            case .replace(let item):
                if let index = items.firstIndex(where: { $0.slot == item.slot }) { items[index] = item } else { items.append(item) }
            case .remove(let slot): items.removeAll { $0.slot == slot }
            }
        }
        items.sort { $0.slot < $1.slot }
        if step.replaceFirst { first = step.first }
    }
}
