import CueStore
import SwiftUI

extension View {
    /// 完成一件 Agent 还在做或在等你的事前问的那一句（点完成圈、把任务卡或会话卡拖到已完成同一份）。照实说会话会怎样：
    /// CuePad 托管的一起结束（`PiSessionState.endsWithTask`），终端里你自己开的不结束、留在终端里。`session` 为 nil 时不弹。
    func agentBusyDialog(_ session: PiSessionState?, isPresented: Binding<Bool>, confirm: @escaping @MainActor () -> Void) -> some View {
        let ends = session?.endsWithTask ?? true
        let endsMessage: LocalizedStringResource = "完成会把它的会话一起结束。"
        let staysMessage: LocalizedStringResource = "这是你在终端里开的会话，完成不会结束它。"
        let endsTitle: LocalizedStringResource = "完成并结束会话"
        let staysTitle: LocalizedStringResource = "完成"
        return dialog(
            "Agent 还在做这件事", isPresented: isPresented, message: ends ? endsMessage : staysMessage,
            buttons: [DialogButton(title: ends ? endsTitle : staysTitle, action: confirm)])
    }
}
