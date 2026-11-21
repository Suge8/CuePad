#if os(macOS)
import Foundation
import Observation

@Observable
final class CardPresses {
    private(set) var presented: UUID?
    private(set) var isSelecting = false
    private(set) var selected: Set<UUID> = []
    @ObservationIgnored var selectable: [UUID] = []

    @ObservationIgnored private var presences: [UUID: CardPresence] = [:]
    @ObservationIgnored private var hovered: UUID?
    @ObservationIgnored private var pressed: UUID?
    private static let releaseGrace: Duration = .milliseconds(80)

    func presence(of card: UUID) -> CardPresence {
        if let presence = presences[card] { return presence }
        let presence = CardPresence()
        presences[card] = presence
        return presence
    }

    func takesClick(on card: UUID, command: Bool) -> Bool {
        guard isSelecting || command else { return false }
        toggle(card)
        return true
    }

    func toggle(_ card: UUID) {
        set(card, selected: !selected.contains(card))
    }

    func selectAll() {
        for card in selectable { set(card, selected: true) }
    }

    func clearSelection() {
        for card in selected { presence(of: card).selected = false }
        selected = []
        isSelecting = false
    }

    private func set(_ card: UUID, selected on: Bool) {
        if on {
            isSelecting = true
            selected.insert(card)
        } else {
            selected.remove(card)
        }
        presence(of: card).selected = on
    }

    func present(_ card: UUID) {
        guard presented != card else { return }
        dismiss()
        presented = card
        presence(of: card).opening = true
    }

    func dismiss() {
        if let card = presented { presence(of: card).opening = false }
        presented = nil
    }

    func opened(_ card: UUID) {
        presence(of: card).opening = false
    }

    var deletable: UUID? { isSelecting || presented != nil ? nil : hovered }

    func hover(_ card: UUID, inside: Bool) {
        if inside {
            hovered = card
        } else {
            if hovered == card { hovered = nil }
            if pressed == card { release() }
        }
    }

    func mouse(down: Bool) {
        guard down else {
            let card = pressed
            Task {
                try? await Task.sleep(for: Self.releaseGrace)
                if pressed == card { release() }
            }
            return
        }
        guard let card = hovered else { return }
        pressed = card
        presence(of: card).pressing = true
    }

    private func release() {
        if let card = pressed { presence(of: card).pressing = false }
        pressed = nil
    }
}

@Observable
final class CardPresence {
    fileprivate(set) var pressing = false
    fileprivate(set) var opening = false
    var held: Bool { pressing || opening }
    fileprivate(set) var selected = false
}
#endif
