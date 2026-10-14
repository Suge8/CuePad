#if os(macOS)
import SwiftUI

extension View {
    func dialog(
        _ title: String, isPresented: Binding<Bool>, message: String? = nil, field: DialogField? = nil, buttons: [DialogButton]
    ) -> some View {
        panel(isPresented: isPresented) { DialogCard(title: title, message: message, field: field, buttons: buttons) }
    }

    func dialog<Item: Identifiable>(
        _ title: String, item: Binding<Item?>, message: String? = nil, buttons: @escaping (Item) -> [DialogButton]
    ) -> some View {
        panel(item: item) { DialogCard(title: title, message: message, field: nil, buttons: buttons($0)) }
    }
}

/// Mac 的确认框：标题、说明、可选的一行输入，右下一排按钮。总有一颗"取消"（Esc 同）；不是取消也不是破坏性的最后一颗是默认按钮（↩），
/// 破坏性的不当默认、要点按，免得顺手一回车删掉东西；它的字是胭脂色。
private struct DialogCard: View {
    let title: String
    let message: String?
    let field: DialogField?
    let buttons: [DialogButton]
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    private var primary: DialogButton? { buttons.last { $0.role == nil && !$0.disabled } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typography.bodyStrong).foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message).font(Typography.secondary).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let field {
                TextField(field.prompt, text: field.text).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { if let primary { run(primary) } }
            }
            HStack(spacing: 8) {
                Spacer()
                if !buttons.contains(where: { $0.role == .cancel }) { Button("取消", role: .cancel) { close() } }
                ForEach(buttons) { button in
                    if button.id == primary?.id {
                        Button(button.title) { run(button) }.keyboardShortcut(.defaultAction)
                    } else {
                        // 破坏性的字用胭脂（同系统提示框），一眼看出这颗会删东西
                        Button(role: button.role) { run(button) } label: {
                            Text(button.title).foregroundStyle(button.role == .destructive ? palette.failure : palette.ink)
                        }
                        .disabled(button.disabled)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 360)
        .background(palette.desk)
        .onAppear { focused = field != nil }
    }

    private func run(_ button: DialogButton) {
        close()
        button.action()
    }
}
#endif
