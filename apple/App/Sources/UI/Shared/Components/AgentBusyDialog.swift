import CueStore
import SwiftUI

extension View {
    /// `session` 为 nil 时不弹。`sleeps`：完成会不会让它休眠（`CompletionAsk`）。
    func agentBusyDialog(_ session: SessionState?, sleeps: Bool, isPresented: Binding<Bool>, confirm: @escaping @MainActor () -> Void) -> some View {
        let sleepsMessage: LocalizedStringResource = "要休眠会话吗？"
        let staysMessage: LocalizedStringResource = "它的会话还有别的事在用，完成后接着跑。"
        let sleepsTitle: LocalizedStringResource = "休眠"
        let staysTitle: LocalizedStringResource = "完成"
        let title: LocalizedStringResource = "Agent 还在做这件事"
        #if os(iOS)
        // 居中的提示框：系统的动作表在手机上不画"取消"，只能点框外
        return alert(Text(title), isPresented: isPresented) {
            Button(action: confirm) { Text(sleeps ? sleepsTitle : staysTitle) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(sleeps ? sleepsMessage : staysMessage)
        }
        #else
        return dialog(title, isPresented: isPresented, message: sleeps ? sleepsMessage : staysMessage, buttons: [DialogButton(title: sleeps ? sleepsTitle : staysTitle, action: confirm)])
        #endif
    }
}
