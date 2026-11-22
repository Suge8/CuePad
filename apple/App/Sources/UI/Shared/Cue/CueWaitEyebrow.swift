import CueStore
import SwiftUI

struct CueWaitEyebrow: View {
    let wait: CueWait
    let index: Int
    let count: Int
    let counter: AccessibilityFocusState<String?>.Binding
    let step: (Int) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            project
            name.layoutPriority(-1)
            Spacer(minLength: Spacing.group)
            LiveText(style: SessionClock.Waited(since: wait.since)).monospacedDigit().fixedSize()
            if count > 1 { position.padding(.leading, Spacing.item) }
        }
        .font(Typography.caption)
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
    }

    @ViewBuilder private var project: some View {
        if let project = workspace.catalog?.project(wait.project) {
            HStack(spacing: Spacing.hair) {
                ProjectGlyph(project: project, size: 11)
                Text(project.shownName).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .fixedSize()
            .padding(.trailing, Spacing.item)
        }
    }

    private var name: some View {
        Button { workspace.openSession(wait.session.id, sessionID: wait.session.sessionID) } label: {
            HStack(spacing: Spacing.hair) {
                Text(wait.title).lineLimit(1)
                Chevron(.forward)
            }
            .foregroundStyle(palette.ink2)
            .contentShape(.rect.inset(by: -Self.reach))
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("打开会话")
    }

    private var position: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            arrow(.back, enabled: index > 0, label: "上一件") { step(-1) }
            #endif
            // 读屏在这一格上下扫换一件（同滑卡、小箭头）：动作挂在已有的元素上，挂在卡上的话整张卡多出一个没有标签的元素（#67）
            Text("\(index + 1)/\(count)").monospacedDigit()
                .accessibilityLabel("第 \(index + 1) 件，共 \(count) 件")
                .accessibilityFocused(counter, equals: wait.id)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
            #if os(macOS)
            arrow(.forward, enabled: index < count - 1, label: "下一件") { step(1) }
            #endif
        }
        .fixedSize()
    }

    #if os(macOS)
    private func arrow(_ direction: Chevron.Direction, enabled: Bool, label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Chevron(direction).frame(width: Self.height, height: Self.height).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
    #endif

    private static let reach: CGFloat = 10
}
