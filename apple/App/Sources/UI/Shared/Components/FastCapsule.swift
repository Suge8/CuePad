import SwiftUI

struct FastCapsule: View {
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
        Image(.fast)
            .chip(on: fast == true, menu: fast == nil)
            .help(fast == true ? Text("加速：开") : fast == false ? Text("加速：关") : Text("加速：未知"))
    }
}
