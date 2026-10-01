#if os(macOS)
import SwiftUI

/// 底部玻璃输入栏：随手记下想法，↩ 存为当前项目的卡片，⌘↩ 直接发出（不存卡，发送记录照常写）。⌥↩ 换行。
struct CaptureBar: View {
    let project: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let width: CGFloat = 620

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("记下想法…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(save)
                    Text("↩ 存为卡片").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                        .opacity(empty ? 0 : 1)
                        .accessibilityHidden(empty)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                // 整条都是输入区：点到加号或留白也进入输入
                .contentShape(.rect(cornerRadius: 24))
                .onTapGesture { focused = true }
                .glass(in: .rect(cornerRadius: 24), interactive: true)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(palette.ink3.opacity(focused ? 0.6 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .animation(Motion.quick, value: focused)
                .animation(Motion.quick, value: empty)
                if !empty {
                    SendControl(project: project) { send($0) }
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                }
            }
            .animation(Motion.snappy, value: empty)
        }
        .frame(maxWidth: Self.width)
        .padding(.horizontal, 24)
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        text = ""
        let project = project
        workspace.attempt { _ = try await workspace.createCard(body: body, in: project) }
        workspace.say("已存为卡片")
        focused = true
    }

    private func send(_ choice: SendChoice) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            if await workspace.send(body, via: choice) { text = "" }
        }
    }
}
#endif
