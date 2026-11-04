import SwiftUI

/// 工具排里的加速开关：开着是选中的胶囊（`chip(on:)`），点一下换；不知道开没开时点开选。
struct PiFastCapsule: View {
    let fast: Bool?
    let choose: (Bool) -> Void

    var body: some View {
        Group {
            if let fast {
                Button { choose(!fast) } label: { label }
                    .buttonStyle(PressStyle())
            } else {
                Menu {
                    Button("开") { choose(true) }
                    Button("关") { choose(false) }
                } label: { label }
                    .menuStyle(.borderlessButton)
            }
        }
        .accessibilityLabel("加速")
        .accessibilityValue(fast == true ? Text("开") : fast == false ? Text("关") : Text("未知"))
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text("加速")
            if fast == true { Text("开") } else if fast == false { Text("关") } else { Text("未知") }
        }
        .chip(on: fast == true)
    }
}
