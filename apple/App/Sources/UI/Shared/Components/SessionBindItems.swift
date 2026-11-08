import CueStore
import SwiftUI

/// 三端任务菜单与 Mac 任务气泡共用的纯关联入口：列本项目未结束的会话，当前关联打勾，末尾可解绑。
/// 候选只读共享的会话列表；关联与解绑交给 Store，不发送正文、不启动或结束会话。
struct SessionBindItems: View {
    let leaf: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let sessions = services.liveSessions.live.filter { ($0.state.projectID ?? Project.defaultID) == leaf.projectID }
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
