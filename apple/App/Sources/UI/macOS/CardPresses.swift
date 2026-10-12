#if os(macOS)
import Foundation
import Observation

/// 各张卡的按下与打开状态（Mac）。按卡分开、各自可观察：按下与打开时只有这张卡的视图重算，
/// 墙上其余卡片与"更早"各行不受牵动（大项目里有上千张）。
@Observable
final class CardPresses {
    /// 编辑页挂在屏上的卡：比 `Workspace.openCard` 晚一步清空，淡出期间仍在。
    private(set) var presented: UUID?

    @ObservationIgnored private var presences: [UUID: CardPresence] = [:]
    /// 鼠标停在哪张卡上、正按着哪张卡（卡片报上来的悬停与 AppKit 的鼠标事件，见 `mouse(down:)`）。
    @ObservationIgnored private var hovered: UUID?
    @ObservationIgnored private var pressed: UUID?
    private static let releaseGrace: Duration = .milliseconds(80)

    /// 这张卡的按下状态；卡片视图只观察自己的那一个。
    func presence(of card: UUID) -> CardPresence {
        if let presence = presences[card] { return presence }
        let presence = CardPresence()
        presences[card] = presence
        return presence
    }

    /// 设成某张卡时编辑页立即挂上，墙上那张卡保持按下，直到 `opened`。
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

    /// 编辑页准备好、开始淡入：墙上那张卡放开。
    func opened(_ card: UUID) {
        presence(of: card).opening = false
    }

    /// 鼠标进出一张卡。拖出卡片也就不再按着它（与按钮拖出即松开一致）。
    func hover(_ card: UUID, inside: Bool) {
        if inside {
            hovered = card
        } else {
            if hovered == card { hovered = nil }
            if pressed == card { release() }
        }
    }

    /// AppKit 分发鼠标按下、松开时调用（本地事件监听，早于 SwiftUI 按钮识别按下）：按下时鼠标停着的那张卡在这一轮就显出按下，
    /// 点下的第一帧就有反馈。
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

/// 一张卡的按下状态。
@Observable
final class CardPresence {
    /// 鼠标正按着这张卡（见 `CardPresses.mouse(down:)`）。
    fileprivate(set) var pressing = false
    /// 刚点开、编辑页还在看不见地准备：卡保持按下，编辑页开始淡入时放开（`CardPresses.opened`）。
    fileprivate(set) var opening = false
    /// 卡显出按下的样子（见 `CardOpenStyle`）。
    var held: Bool { pressing || opening }
}
#endif
