import Foundation

nonisolated extension CueNow {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decay = try values.decodeIfPresent([Decay].self, forKey: .decay)
        self.init(
            name: try values.decode(String.self, forKey: .name), cue: try values.decode(Brain.self, forKey: .cue),
            tally: try values.decode(Tally.self, forKey: .tally), advancing: try values.decode(Int.self, forKey: .advancing),
            subagents: try values.decode(Int.self, forKey: .subagents), items: try values.decode([Item].self, forKey: .items),
            first: try values.decodeIfPresent(Wait.self, forKey: .first), at: try values.decode(Date.self, forKey: .at),
            elsewhere: try values.decodeIfPresent(String.self, forKey: .elsewhere), decay: decay ?? [],
            unconfirmed: try values.decodeIfPresent(Bool.self, forKey: .unconfirmed) ?? true,
            cueUntil: try values.decodeIfPresent(Date.self, forKey: .cueUntil))
        if decay == nil { migrateUnconfirmedRuntime() }
    }

    /// 旧缓存没有 host 期限与贡献归属，只能保留任务和最后进度，不能据旧正数签发当前运行断言。
    private mutating func migrateUnconfirmedRuntime() {
        self = settled
        items = items.enumerated().map { index, item in
            var item = item
            item.slot = index
            return item
        }
        let changes: [Decay.Change] = items.filter { $0.kind != .done }.map {
            .update(slot: $0.slot, kind: .unconfirmed, since: $0.since, subagents: 0)
        }
        apply(Decay(
            at: at, tally: Tally(), advancing: advancing, subagents: 0,
            items: changes, first: nil, replaceFirst: true))
    }
}

nonisolated extension CueNow.Item {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id), kind: try values.decode(Kind.self, forKey: .kind),
            name: try values.decode(String.self, forKey: .name), since: try values.decode(Date.self, forKey: .since),
            subagents: try values.decode(Int.self, forKey: .subagents), slot: try values.decodeIfPresent(Int.self, forKey: .slot) ?? 0)
    }
}

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
            replaceFirst: try values.decode(Bool.self, forKey: .replaceFirst))
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
    }
}

nonisolated extension CueNow.Decay.Change {
    private enum Operation: Int, Codable { case update = 0, replace = 1, remove = 2 }

    init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        switch try values.decode(Operation.self) {
        case .update:
            self = .update(slot: try values.decode(Int.self), kind: try values.decode(CueNow.Item.Kind.self),
                           since: try values.decode(Date.self), subagents: try values.decode(Int.self))
        case .replace: self = .replace(try values.decode(CueNow.Item.self))
        case .remove: self = .remove(slot: try values.decode(Int.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        switch self {
        case .update(let slot, let kind, let since, let subagents):
            try values.encode(Operation.update)
            try values.encode(slot)
            try values.encode(kind)
            try values.encode(since)
            try values.encode(subagents)
        case .replace(let item):
            try values.encode(Operation.replace)
            try values.encode(item)
        case .remove(let slot):
            try values.encode(Operation.remove)
            try values.encode(slot)
        }
    }
}
