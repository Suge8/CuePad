import CueStore
import SwiftUI

extension View {
    /// `session` 为 nil 时不弹。`sleeps`：完成会不会让它休眠（`CompletionAsk`）。
    func agentBusyDialog(_ session: SessionState?, sleeps: Bool, isPresented: Binding<Bool>, confirm: @escaping @MainActor () -> Void) -> some View {
        let sleepsMessage: LocalizedStringResource = "完成后它的会话会休眠，再对它说话就醒。"
        let staysMessage: LocalizedStringResource = "它的会话还有别的事在用，完成后接着跑。"
        let sleepsTitle: LocalizedStringResource = "完成并休眠"
        let staysTitle: LocalizedStringResource = "完成"
        return dialog(
            "Agent 还在做这件事", isPresented: isPresented, message: sleeps ? sleepsMessage : staysMessage,
            buttons: [DialogButton(title: sleeps ? sleepsTitle : staysTitle, action: confirm)])
    }
}
