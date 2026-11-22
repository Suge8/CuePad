import CueStore
import SwiftUI

/// iOS 是系统菜单（`MenuButton`），Mac 弹 AppKit 菜单（`ChoiceMenu`，SwiftUI 在 Mac 上丢掉菜单项里的产品标志）。
struct AgentCapsule: View {
    let pick: AgentPick
    #if os(macOS)
    @State private var anchor = PopUpAnchor()
    #endif

    var body: some View {
        if !pick.choosable {
            label.accessibilityElement(children: .ignore).accessibilityLabel("用 \(pick.current.name)")
        } else {
            #if os(macOS)
            Button { if let view = anchor.view { ChoiceMenu.popUp(pick.menu, below: view) } } label: { label }
                .buttonStyle(PressStyle())
                .popUpAnchor(anchor)
                .accessibilityLabel("Agent")
                .accessibilityValue(pick.current.name)
            #else
            MenuButton(sections: pick.menu, accessibilityLabel: "Agent", value: pick.current.name) { label }
            #endif
        }
    }

    private var label: some View {
        let kind = pick.current
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: ModelPick.gap) {
                ModelBadge(mark: kind.mark, binding: nil).readerHidden(true)
                Text(kind.name).lineLimit(1).contentTransition(.opacity)
            }.fixedSize()
            ModelBadge(mark: kind.mark, binding: nil).readerHidden(true)
        }
        .chip(menu: pick.choosable)
        .help(kind.name)
        .animation(Motion.fade, value: kind)
    }
}


struct ModelBadge: View {
    let mark: BrandMark?
    let binding: QuotaMeter.Window?
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let binding {
                QuotaRing(binding)
                    .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: binding)
            }
            mark?.image
                .font(.system(size: side * 0.52))
                .contentTransition(.opacity)
        }
        .frame(width: side, height: side)
    }
}


/// SwiftUI 的 repeatForever 每帧在 App 进程里重算，一直没送达时会话页静止也占约 9% CPU，所以一层胶囊底色盖在内容上一明一暗，交给渲染服务（`LoopLayer` 的 `pulse`）。
struct Breathing: ViewModifier {
    let active: Bool
    @Environment(\.palette) private var palette
    @LoopsPlay private var breathes

    func body(content: Content) -> some View {
        content.overlay {
            if active, breathes { LoopLayer(kind: .pulse, color: palette.fill).mask { content }.allowsHitTesting(false) }
        }
    }
}
