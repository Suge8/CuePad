import CueStore
import SwiftUI

/// 会话页的纯关联菜单，三端共用同一份 Store 候选与当前关联；历史用过的任务不显示为当前关联。
struct SessionTaskBindItems: View {
    let session: PiSessionState
    let link: SessionTaskLink
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let using = link.tasks.filter { $0.task.piSessionID == session.sessionID }
        Menu("绑定到任务", icon: .link) {
            ForEach(using) { item in
                Toggle(Dotted(item.parent?.title, item.task.title).visible, isOn: .constant(true))
            }
            ForEach(link.bindable) { item in
                Button(Dotted(item.parent?.title, item.task.title).visible) {
                    let (sessionID, task) = (session.sessionID, item.task.id)
                    workspace.perform { try await $0.bindSession(sessionID, to: task) }
                }
            }
            if using.isEmpty, link.bindable.isEmpty {
                Button("本项目没有可绑定的任务") {}.disabled(true)
            }
        }
        if !using.isEmpty {
            Menu("解除绑定", icon: .unlink) {
                ForEach(using) { item in
                    Button(Dotted(item.parent?.title, item.task.title).visible) {
                        let task = item.task.id
                        workspace.perform { try await $0.unbindSession(from: task) }
                    }
                }
            }
        }
    }
}
