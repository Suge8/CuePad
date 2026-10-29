import Foundation

nonisolated extension CueNow {
    /// 按各 host 的实际期限预计算的差量；归属在计算时按整件去重，不把一台的到期误套给别台。
    /// 只存有变化的可见行，未列出的工作也已经计入完整数字账。
    struct Decay: Codable, Hashable, Sendable {
        var at: Date
        var tally: Tally
        var advancing: Int
        var subagents: Int
        var items: [Change]
        var first: Wait?
        var replaceFirst: Bool

        enum CodingKeys: String, CodingKey { case at = "t", tally = "c", advancing = "a", subagents = "s", items = "i", first = "f", replaceFirst = "r" }

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
