import Foundation

nonisolated extension CueNow.Decay {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var counts = try values.nestedUnkeyedContainer(forKey: .tally)
        self.init(
            at: try values.decode(Date.self, forKey: .at),
            tally: CueNow.Tally(asks: try counts.decode(Int.self), reply: try counts.decode(Int.self),
                               moving: try counts.decode(Int.self), delegating: try counts.decode(Int.self)),
            advancing: try values.decode(Int.self, forKey: .advancing), subagents: try values.decode(Int.self, forKey: .subagents),
            items: try values.decode([Change].self, forKey: .items), first: try values.decodeIfPresent(CueNow.Wait.self, forKey: .first),
            replaceFirst: try values.decode(Bool.self, forKey: .replaceFirst), agentCount: try values.decodeIfPresent(Int.self, forKey: .agentCount))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(at, forKey: .at)
        var counts = values.nestedUnkeyedContainer(forKey: .tally)
        try counts.encode(tally.asks)
        try counts.encode(tally.reply)
        try counts.encode(tally.moving)
        try counts.encode(tally.delegating)
        try values.encode(advancing, forKey: .advancing)
        try values.encode(subagents, forKey: .subagents)
        try values.encode(items, forKey: .items)
        try values.encodeIfPresent(first, forKey: .first)
        try values.encode(replaceFirst, forKey: .replaceFirst)
        try values.encodeIfPresent(agentCount, forKey: .agentCount)
    }
}

nonisolated extension CueNow.Decay.Change {
    private enum Operation: Int, Codable { case update = 0, replace = 1, remove = 2 }

    init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        switch try values.decode(Operation.self) {
        case .update:
            self = .update(slot: try values.decode(Int.self), kind: try values.decode(CueNow.Item.Kind.self),
                           since: try values.decode(Date.self), subagents: try values.decode(Int.self),
                           offline: values.isAtEnd ? nil : try values.decode(String.self))
        case .replace: self = .replace(try values.decode(CueNow.Item.self))
        case .remove: self = .remove(slot: try values.decode(Int.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        switch self {
        // 那台没开（`offline`）只在有时接在末尾：旧版读到四项就停，不认它也不出错
        case .update(let slot, let kind, let since, let subagents, let offline):
            try values.encode(Operation.update)
            try values.encode(slot)
            try values.encode(kind)
            try values.encode(since)
            try values.encode(subagents)
            if let offline { try values.encode(offline) }
        case .replace(let item):
            try values.encode(Operation.replace)
            try values.encode(item)
        case .remove(let slot):
            try values.encode(Operation.remove)
            try values.encode(slot)
        }
    }
}
