#if os(macOS)
import SwiftUI

extension View {
    func dialog(
        _ title: LocalizedStringResource, isPresented: Binding<Bool>, message: LocalizedStringResource? = nil, field: DialogField? = nil, buttons: [DialogButton]
    ) -> some View {
        panel(isPresented: isPresented) { DialogCard(title: title, message: message, field: field, buttons: buttons) }
    }

    func dialog<Item: Identifiable>(
        _ title: LocalizedStringResource, item: Binding<Item?>, message: LocalizedStringResource? = nil, buttons: @escaping (Item) -> [DialogButton]
    ) -> some View {
        panel(item: item) { DialogCard(title: title, message: message, field: nil, buttons: buttons($0)) }
    }
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
