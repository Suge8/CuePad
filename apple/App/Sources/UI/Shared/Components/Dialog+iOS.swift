#if os(iOS)
import SwiftUI

extension View {
    func dialog(
        _ title: String, isPresented: Binding<Bool>, message: String? = nil, field: DialogField? = nil, buttons: [DialogButton]
    ) -> some View {
        Group {
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
    }

    func dialog<Item: Identifiable>(
        _ title: String, item: Binding<Item?>, message: String? = nil, buttons: @escaping (Item) -> [DialogButton]
    ) -> some View {
        confirmationDialog(
            title, isPresented: Binding { item.wrappedValue != nil } set: { if !$0 { item.wrappedValue = nil } },
            titleVisibility: .visible, presenting: item.wrappedValue
        ) { shown in
            ForEach(buttons(shown)) { Button($0.title, role: $0.role, action: $0.action).disabled($0.disabled) }
        } message: { _ in
            if let message { Text(message) }
        }
    }
}
#endif
