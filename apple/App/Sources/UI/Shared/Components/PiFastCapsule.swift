import SwiftUI

/// 工具排里的加速开关：开着是选中的胶囊（`chip(on:)`），点一下换；不知道开没开时点开菜单选（手机上经 `MenuButton`，键盘不跳）。
struct PiFastCapsule: View {
    let fast: Bool?
    let choose: (Bool) -> Void

    var body: some View {
        if let fast {
            Button { choose(!fast) } label: { label }
                .buttonStyle(PressStyle())
                .accessibilityLabel("加速")
                .accessibilityValue(fast ? Text("开") : Text("关"))
        } else {
            MenuButton(sections: [
                ChoiceMenu.Section(choices: [
                    ChoiceMenu.Choice(title: "开") { choose(true) },
                    ChoiceMenu.Choice(title: "关") { choose(false) },
                ]),
            ], accessibilityLabel: "加速", value: String(localized: "未知")) { label }
        }
    }

    private var label: some View {
        // 工具排放不下时（`ConfigRow`）只写"加速"：开没开看选中底，读屏照说
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text("加速")
                if fast == true { Text("开") } else if fast == false { Text("关") } else { Text("未知") }
            }
            Text("加速")
        }
        .chip(on: fast == true, menu: fast == nil)
    }
}
