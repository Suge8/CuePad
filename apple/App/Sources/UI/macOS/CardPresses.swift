#if os(macOS)
import Foundation
import Observation

/// 按卡分开、各自可观察：按下、打开、选中时只有这张卡的视图重算，墙上其余卡片与"更早"各行不受牵动（大项目里有上千张）。
@Observable
final class CardPresses {
    /// 编辑页挂在屏上的卡：比 `Workspace.openCard` 晚一步清空，淡出期间仍在。
    private(set) var presented: UUID?
    private(set) var isSelecting = false
    /// 选中的卡（批量操作）。只有底部的操作栏读它，卡各自读自己的 `CardPresence.selected`。
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

    func beginSelecting() { isSelecting = true }

    /// 在选择中或按着 ⌘ 时这一下是选上或取消（返回 true，不打开）。
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

    /// 拖出卡片也就不再按着它（与按钮拖出即松开一致）。
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
            // 松开到"打开中"接上之间隔着一两次更新：这时就放开，卡片会先亮一下再压暗回去。
            // 稍等再放开；打开了就由"打开中"接着按住，没打开（取消）这时才复原
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
