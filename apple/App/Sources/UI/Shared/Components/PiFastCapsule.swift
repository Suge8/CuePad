import SwiftUI

struct PiFastCapsule: View {
    let fast: Bool?
    let choose: (Bool) -> Void
    @Environment(\.palette) private var palette

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
        .font(Typography.meta.weight(.medium))
        .foregroundStyle(fast == true ? palette.ink : palette.ink3)
        .padding(.horizontal, 10)
        .configCapsuleHeight()
        .background(palette.fill, in: .capsule)
        .frame(minHeight: ConfigCapsule.hitHeight)
        .contentShape(.capsule)
    }
}
