import CueStore
import SwiftUI

extension View {
    /// `session` 为 nil 时不弹。
    func agentBusyDialog(_ session: SessionState?, isPresented: Binding<Bool>, confirm: @escaping @MainActor () -> Void) -> some View {
        let ends = session?.endsWithTask ?? true
        let endsMessage: LocalizedStringResource = "完成会把它的会话一起结束。"
        let staysMessage: LocalizedStringResource = "这个会话不是为这件事开的，完成不会结束它。"
        let endsTitle: LocalizedStringResource = "完成并结束会话"
        let staysTitle: LocalizedStringResource = "完成"
        return dialog(
            "Agent 还在做这件事", isPresented: isPresented, message: ends ? endsMessage : staysMessage,
            buttons: [DialogButton(title: ends ? endsTitle : staysTitle, action: confirm)])
    }
}
