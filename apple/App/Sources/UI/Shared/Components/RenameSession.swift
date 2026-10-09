import CueStore
import SwiftUI

/// 改会话名的对话框（iOS 的 Agent 页与会话页、Mac 侧栏、Agent 整页与会话页共用）：就地一个输入框，预填现在的名字，
/// 确定后经 `AppServices.rename` 让 Pi 改（会话名只来自 Pi）。没改动或空着时"改名"不可点。
struct RenameSession: ViewModifier {
    @Binding var session: PiSessionState?
    @Environment(Workspace.self) private var workspace
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("重命名会话", isPresented: Binding { session != nil } set: { if !$0 { session = nil } }, presenting: session) { target in
                TextField("会话名", text: $name)
                Button("取消", role: .cancel) {}
                Button("改名") {
                    let name = name, services = workspace.services
                    workspace.attempt { try await services.rename(target, to: name) }
                }
                .disabled(PiRename.line(name) == nil || PiRename.line(name) == PiRename.line(target.title))
            }
            .onChange(of: session?.id, initial: true) { name = session?.title ?? "" }
    }
}

extension View {
    /// `session` 非空时弹出改名框，关掉时置回 nil。
    func renameSession(_ session: Binding<PiSessionState?>) -> some View { modifier(RenameSession(session: session)) }
}

extension MacDelivery {
    /// 能改名：读得到的会话（旧版扩展的收不到命令）；已结束的也能改，Mac 先在后台恢复它。
    static func canRename(_ session: PiSessionState) -> Bool { session.state != .known(.incompatible) }
}
