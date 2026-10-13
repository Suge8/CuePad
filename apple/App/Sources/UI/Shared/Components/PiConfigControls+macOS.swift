#if os(macOS)
import AppKit
import CueStore
import SwiftUI

extension PiConfigControls {
    /// 弹出选择菜单（点模型胶囊与键盘共用）：模型按提供方分组（标题与每项带提供方图标；有订阅额度的分组标题写各窗口的用量，`PiModelLabel.title`）、当前打勾；思考强度是当前模型支持的档。
    func open(_ pick: PiConfigPick) {
        guard let anchor = anchors[pick]?.view else { return }
        switch pick {
        case .model:
            let now = Date.now
            let sections = PiModelLabel.groups(session.models).map { group in
                let image = group.provider.nsImage
                return ChoiceMenu.Section(
                    title: PiModelLabel.title(group.provider, quotas: services.accountQuotas.items, at: now), image: image,
                    choices: group.models.map { model in
                        ChoiceMenu.Choice(
                            // 原生菜单项没有单独的读屏文字，分段直接写逗号
                            title: model.name.isEmpty ? model.key.id : model.name, subtitle: PiModelLabel.levels(model).spoken,
                            image: image, checked: shown.model?.key == model.key) { configure(PiConfig(model: model.key)) }
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
