#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension PiConfigControls {
    /// 弹出选择菜单（点 Agent、模型胶囊与键盘共用）：模型按调用方给的分组（组名与每项可带提供方图标；没给组名的写提供方与它的额度用量，`PiModelLabel.title`）、当前打勾；思考强度是可选的档。
    func open(_ pick: PiConfigPick) {
        guard let anchor = anchors[pick]?.view else { return }
        switch pick {
        case .agent:
            if let agent { ChoiceMenu.popUp(agent.menu, below: anchor) }
        case .model:
            ChoiceMenu.popUp(groups.menu(quotas: services.accountQuotas.items, at: .now), below: anchor)
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
