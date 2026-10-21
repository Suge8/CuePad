#if os(macOS)
import AppKit
import SwiftUI

extension PiConfigControls {
    /// 弹出选择菜单（点模型胶囊与键盘共用）：模型菜单（`PiModelMenu`）；思考强度是可选的档。
    func open(_ pick: PiConfigPick) {
        guard let anchor = anchors[pick]?.view else { return }
        switch pick {
        case .model:
            ChoiceMenu.popUp(models.sections(quotas: services.accountQuotas.items, at: .now), below: anchor)
        case .thinking:
            ChoiceMenu.popUp([ChoiceMenu.Section(title: "思考强度", choices: levels.map { level in
                ChoiceMenu.Choice(title: level.label, checked: shown.thinking == level) { chooseThinking(level) }
            })], below: anchor)
        }
    }
}

/// 键盘弹出的菜单贴着的控件：控件背景里一个空的 AppKit 视图，菜单按它的位置弹出。
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
