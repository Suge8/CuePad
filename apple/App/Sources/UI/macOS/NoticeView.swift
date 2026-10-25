#if os(macOS)
import CueStore
import SwiftUI

/// 提示里的动作（撤销、归档）：点了收起提示并做那件事；撤销另有 ⌘Z。
private struct NoticeActionButton: View {
    let action: Workspace.NoticeAction
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action.title) { workspace.run(action) }
        .font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
        .buttonStyle(PressStyle())
        .padding(.horizontal, 10).frame(height: 28)
        .keyboardShortcut(action.isUndo ? KeyboardShortcut("z", modifiers: .command) : nil)
    }
}

/// 顶部居中的短提示：操作结果与错误；带动作的（撤销、完成后的归档）右边一个按钮，撤销另有 ⌘Z。
struct NoticeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                HStack(spacing: 0) {
                    Button { if let link = notice.link { workspace.go(to: link) } } label: {
                        HStack(spacing: 6) {
                            Label { Text(notice.text) } icon: { Image(notice.tone.icon) }
                            if notice.link != nil { Image(.forward).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
                        }
                        .font(Typography.secondary.weight(.medium))
                        .foregroundStyle(notice.isError ? palette.failure : palette.ink)
                        .padding(.leading, 14).padding(.trailing, notice.action == nil ? 14 : 4).frame(height: 34)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(notice.link == nil)
                    if let action = notice.action { NoticeActionButton(action: action).padding(.trailing, 4) }
                }
                .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(HandOff.quick, value: workspace.notice)
    }
}
#endif
