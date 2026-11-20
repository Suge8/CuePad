import CueStore
import SwiftUI

extension View {
    /// `session` 为 nil 时不弹。`sleeps`：完成会不会让它休眠（`CompletionAsk`）。
    func agentBusyDialog(
        _ session: SessionState?, sleeps: Bool, isPresented: Binding<Bool>, confirm: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void
    ) -> some View {
        let sleepsMessage: LocalizedStringResource = "要休眠会话吗？"
        let staysMessage: LocalizedStringResource = "它的会话还有别的事在用，完成后接着跑。"
        let sleepsTitle: LocalizedStringResource = "休眠"
        let staysTitle: LocalizedStringResource = "完成"
        return ask("Agent 还在做这件事", isPresented: isPresented, message: sleeps ? sleepsMessage : staysMessage,
                   button: DialogButton(title: sleeps ? sleepsTitle : staysTitle, action: confirm), cancel: cancel)
    }
}
