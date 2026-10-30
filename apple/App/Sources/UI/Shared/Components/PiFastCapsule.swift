import SwiftUI

struct PiFastCapsule: View {
    let fast: Bool?
    let toggle: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: toggle) {
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
        .buttonStyle(PressStyle())
        .accessibilityLabel("加速")
        .accessibilityValue(fast == true ? Text("开") : fast == false ? Text("关") : Text("未知"))
    }
}
