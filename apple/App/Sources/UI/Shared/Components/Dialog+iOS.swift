#if os(iOS)
import SwiftUI

extension View {
    func dialog(
        _ title: LocalizedStringResource, isPresented: Binding<Bool>, message: LocalizedStringResource? = nil, field: DialogField? = nil, buttons: [DialogButton]
    ) -> some View {
        Group {
            if let field {
                self.alert(Text(title), isPresented: isPresented) {
                    TextField(String(localized: field.prompt), text: field.text)
                    ForEach(buttons) { button in Button(role: button.role, action: button.action) { Text(button.title) }.disabled(button.disabled) }
                } message: {
                    if let message { Text(message) }
                }
            } else {
                self.confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: .visible) {
                    ForEach(buttons) { button in Button(role: button.role, action: button.action) { Text(button.title) }.disabled(button.disabled) }
                } message: {
                    if let message { Text(message) }
                }
            }
        }
    }

    func dialog<Item: Identifiable>(
        _ title: LocalizedStringResource, item: Binding<Item?>, message: LocalizedStringResource? = nil, buttons: @escaping (Item) -> [DialogButton]
    ) -> some View {
        confirmationDialog(
            Text(title), isPresented: Binding { item.wrappedValue != nil } set: { if !$0 { item.wrappedValue = nil } },
            titleVisibility: .visible, presenting: item.wrappedValue
        ) { shown in
            ForEach(buttons(shown)) { button in Button(role: button.role, action: button.action) { Text(button.title) }.disabled(button.disabled) }
        } message: { _ in
            if let message { Text(message) }
        }
    }
}
#endif
