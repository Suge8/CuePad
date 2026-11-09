#if os(macOS)
import AppKit
import SwiftUI

extension PiConfigControls {
    func open(_ pick: PiConfigPick) {
        guard let anchor = anchors[pick]?.view else { return }
        switch pick {
        case .model:
            ChoiceMenu.popUp(models.sections(quotas: services.accountQuotas.items, at: .now), below: anchor)
        case .thinking:
            ChoiceMenu.popUp([ChoiceMenu.Section(title: "思考强度", choices: levels.map { level in
                ChoiceMenu.Choice(title: .verbatim(level.label), checked: shown.thinking == level) { chooseThinking(level) }
            })], below: anchor)
        }
    }
}

final class PopUpAnchor {
    weak var view: NSView?
}

extension View {
    func popUpAnchor(_ anchor: PopUpAnchor?) -> some View {
        background { if let anchor { PopUpAnchorView(anchor: anchor) } }
    }
}

private struct PopUpAnchorView: NSViewRepresentable {
    let anchor: PopUpAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
#endif
