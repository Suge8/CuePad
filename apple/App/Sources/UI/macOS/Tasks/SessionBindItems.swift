#if os(macOS)
import CueStore
import SwiftUI

/// 给叶子任务挑一个会话绑上（菜单项）：最上面"开新会话"（不接着用绑着的或上一步的会话，`Workspace.startFresh`），
/// 其下本项目此刻在线的会话（所有 Mac 上的），绑着的那个打勾；绑着会话时末尾"解除绑定"。
/// 任务的右键（"绑定会话"子菜单）与任务浮窗里的"绑定会话"共用。一个会话可以绑好几件事，选了别的会话就是改绑。
struct SessionBindItems: View {
    let leaf: Card
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let sessions = workspace.sendState.onlineTargets(for: leaf.projectID).filter { $0.state.projectID == leaf.projectID }
        Button("开新会话", icon: .add) { workspace.startFresh(leaf) }
        Divider()
        ForEach(sessions) { item in
            let sessionID = item.state.sessionID
            Toggle(item.state.title, isOn: Binding(get: { leaf.piSessionID == sessionID }, set: { if $0 { bind(sessionID) } }))
        }
        if sessions.isEmpty { Button("本项目没有在跑的会话") {}.disabled(true) }
        if leaf.piSessionID != nil {
            Divider()
            Button("解除绑定", icon: .unlink) {
                let id = leaf.id
                workspace.perform { try await $0.unbindSession(from: id) }
            }
        }
    }

    private func bind(_ sessionID: String) {
        let id = leaf.id
        workspace.perform { try await $0.bindSession(sessionID, to: id) }
    }
}
#endif
