#if os(macOS)
import SwiftUI

extension View {
    func dialog(
        _ title: LocalizedStringResource, isPresented: Binding<Bool>, message: LocalizedStringResource? = nil, field: DialogField? = nil, buttons: [DialogButton]
    ) -> some View {
        panel(isPresented: isPresented) { DialogCard(title: title, message: message, field: field, buttons: buttons) }
    }

    /// `cancel`：没答应就关了（取消、Esc、点外面）。
    func ask(
        _ title: LocalizedStringResource, isPresented: Binding<Bool>, message: LocalizedStringResource? = nil, button: DialogButton,
        cancel: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(Ask(title: title, isPresented: isPresented, message: message, button: button, cancel: cancel))
    }

    func dialog<Item: Identifiable>(
        _ title: LocalizedStringResource, item: Binding<Item?>, message: LocalizedStringResource? = nil, buttons: @escaping (Item) -> [DialogButton]
    ) -> some View {
        panel(item: item) { DialogCard(title: title, message: message, field: nil, buttons: buttons($0)) }
    }
}

private struct Ask: ViewModifier {
    let title: LocalizedStringResource
    @Binding var isPresented: Bool
    let message: LocalizedStringResource?
    let button: DialogButton
    let cancel: @MainActor () -> Void
    @State private var answered = Answered()

    func body(content: Content) -> some View {
        let answered = answered, shown = $isPresented, cancel = cancel
        content.dialog(title, isPresented: Binding { shown.wrappedValue } set: { open in
            shown.wrappedValue = open
            guard !open else { return }
            // 关与办在同一个调用里（`DialogCard.run` 先关后办）：等这个调用走完，再看这一回是不是答应了
            Task { @MainActor in
                if !answered.yes { cancel() }
                answered.yes = false
            }
        }, message: message, buttons: [DialogButton(title: button.title, role: button.role, disabled: button.disabled) {
            answered.yes = true
            button.action()
        }])
    }

    @MainActor private final class Answered { var yes = false }
}

/// 破坏性的不当默认、要点按，免得顺手一回车删掉东西。
private struct DialogCard: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource?
    let field: DialogField?
    let buttons: [DialogButton]
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    private var primary: DialogButton? { buttons.last { $0.role == nil && !$0.disabled } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(title).font(Typography.bodyStrong).foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message).font(Typography.secondary).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let field {
                TextField(String(localized: field.prompt), text: field.text).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { if let primary { run(primary) } }
            }
            HStack(spacing: Spacing.item) {
                Spacer()
                if !buttons.contains(where: { $0.role == .cancel }) { Button("取消", role: .cancel) { close() } }
                ForEach(buttons) { button in
                    if button.id == primary?.id {
                        Button { run(button) } label: { Text(button.title) }.keyboardShortcut(.defaultAction)
                    } else {
                        // 破坏性的字用胭脂（同系统提示框），一眼看出这颗会删东西
                        Button(role: button.role) { run(button) } label: {
                            Text(button.title).foregroundStyle(button.role == .destructive ? palette.failure : palette.ink)
                        }
                        .disabled(button.disabled)
                    }
                }
            }
            .padding(.top, Spacing.tight)
        }
        .padding(Spacing.panel)
        .frame(width: 360)
        .onAppear { focused = field != nil }
    }

    private func run(_ button: DialogButton) {
        close()
        button.action()
    }
}
#endif
