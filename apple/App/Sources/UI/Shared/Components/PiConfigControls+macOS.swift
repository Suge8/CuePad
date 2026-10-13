#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension PiConfigControls {
    /// 键盘打开的菜单：与点胶囊同样的选项（模型按提供方分组、当前打勾；思考强度是当前模型支持的档），系统菜单，方向键选、↩ 确认、Esc 关。
    func open(_ pick: PiConfigPick) {
        guard let anchor = anchors[pick]?.view else { return }
        switch pick {
        case .model:
            let sections = PiModelLabel.groups(session.models).map { group in
                ChoiceMenu.Section(title: group.provider.name, choices: group.models.map { model in
                    ChoiceMenu.Choice(
                        // 原生菜单项没有单独的读屏文字，分段直接写逗号
                        title: model.name.isEmpty ? model.key.id : model.name, subtitle: PiModelLabel.levels(model).spoken,
                        checked: shown.model?.key == model.key) { configure(PiConfig(model: model.key)) }
                })
            }
            ChoiceMenu.popUp(sections, below: anchor)
        case .thinking:
            let levels = shown.model?.thinkingLevels ?? []
            ChoiceMenu.popUp([ChoiceMenu.Section(title: "思考强度", choices: levels.map { level in
                ChoiceMenu.Choice(title: level.label, subtitle: nil, checked: shown.thinking == level) { configure(PiConfig(thinking: level)) }
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
