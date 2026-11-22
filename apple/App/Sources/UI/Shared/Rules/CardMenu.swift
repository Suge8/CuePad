import CueStore

nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case complete, reopen, move, archive, pin, unpin, copy, trash
        case more
        case open
        case select
        case indent, outdent
    }

    struct Swipes: Equatable, Sendable {
        var leading: [Item]
        var trailing: [Item]
    }

    static func swipes(for card: Card, indent: Bool) -> Swipes {
        guard card.isTask else { return Swipes(leading: [], trailing: [.trash]) }
        return Swipes(leading: indent ? [.indent] : [], trailing: [.trash, .more])
    }

    static func swipeMore(for card: Card, opens: Bool) -> [Item] {
        (opens ? [.open] : []) + [card.status == .done ? .reopen : .complete] + pin(card) + [.copy, .archive]
    }

    static func sections(for card: Card, selectable: Bool = false, opens: Bool = false) -> [[Item]] {
        let head: [[Item]] = opens ? [[.open]] : []
        return switch card.status {
        case nil: [[.move, .archive], (selectable ? [.select] : []) + [.trash]]
        case .done: head + [pin(card) + [.reopen, .copy], [.archive, .trash]]
        case .todo, .inProgress: head + [pin(card) + [.complete, .copy], [.archive, .trash]]
        }
    }

    static func more(for idea: Card) -> [[Item]] {
        [[idea.isPinned ? .unpin : .pin, .move, .copy], [.archive, .trash]]
    }

    private static func pin(_ task: Card) -> [Item] { task.parentID == nil ? [task.isPinned ? .unpin : .pin] : [] }
}
