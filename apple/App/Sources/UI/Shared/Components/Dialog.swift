import SwiftUI

/// 确认框与提示框里的一颗按钮；按下后框自己关。
struct DialogButton: Identifiable {
    let title: String
    var role: ButtonRole?
    var disabled = false
    let action: @MainActor () -> Void

    var id: String { title }
}

/// 提示框里要写一行字时（如新建任务的名字）。
struct DialogField {
    let prompt: String
    let text: Binding<String>
}

extension View {
    /// 确认框与提示框：调用处只给状态、文案与按钮，平台只换呈现。iOS 是系统的（带输入框时是 alert，否则是 confirmationDialog）；
    /// Mac 是 `panel` 里的一张小卡（`DialogCard`）——Mac 的系统提示框也是窗口 sheet，开、关各占主线程约 300ms。
    func dialog(
        _ title: String, isPresented: Binding<Bool>, message: String? = nil, field: DialogField? = nil, buttons: [DialogButton]
    ) -> some View {
        #if os(iOS)
        return Group {
            if let field {
                self.alert(title, isPresented: isPresented) {
                    TextField(field.prompt, text: field.text)
                    ForEach(buttons) { Button($0.title, role: $0.role, action: $0.action).disabled($0.disabled) }
                } message: {
                    if let message { Text(message) }
                }
            } else {
                self.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
                    ForEach(buttons) { Button($0.title, role: $0.role, action: $0.action).disabled($0.disabled) }
                } message: {
                    if let message { Text(message) }
                }
            }
        }
        #else
        return panel(isPresented: isPresented) { DialogCard(title: title, message: message, field: field, buttons: buttons) }
        #endif
    }

    /// 对某一项的确认（如结束某个会话）：`item` 非空时弹出，关掉时置回 nil。
    func dialog<Item: Identifiable>(
        _ title: String, item: Binding<Item?>, message: String? = nil, buttons: @escaping (Item) -> [DialogButton]
    ) -> some View {
        #if os(iOS)
        return self.confirmationDialog(
            title, isPresented: Binding { item.wrappedValue != nil } set: { if !$0 { item.wrappedValue = nil } },
            titleVisibility: .visible, presenting: item.wrappedValue
        ) { shown in
            ForEach(buttons(shown)) { Button($0.title, role: $0.role, action: $0.action).disabled($0.disabled) }
        } message: { _ in
            if let message { Text(message) }
        }
        #else
        return panel(item: item) { DialogCard(title: title, message: message, field: nil, buttons: buttons($0)) }
        #endif
    }
}

#if os(macOS)
/// Mac 的确认框：标题、说明、可选的一行输入，右下一排按钮。总有一颗"取消"（Esc 同）；不是取消也不是破坏性的最后一颗是默认按钮（↩），
/// 破坏性的不当默认、要点按，免得顺手一回车删掉东西。
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
                        Button(button.title, role: button.role) { run(button) }.disabled(button.disabled)
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
