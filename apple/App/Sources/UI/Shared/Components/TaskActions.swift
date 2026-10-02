#if os(macOS)
import CuePi
#endif
import CueStore
import SwiftUI

/// 任务操作（Mac 右键、iOS 长按共用）：编辑、发送与复制、转为卡片、移到项目、删除。
/// 编辑是行内的，由行提供；发送是平台各自的：Mac 发给某个 Pi 会话并关联上它，iOS 发到 Mac。
struct TaskActions: View {
    let task: CueTask
    var edit: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    #if os(macOS)
    @Environment(AppServices.self) private var services
    #else
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let id = task.id, content = task.content, project = task.projectID
        let projects = workspace.catalog?.projects ?? []
        if let edit { Button("编辑", systemImage: "pencil", action: edit) }
        sending
        Button("转为卡片", systemImage: "rectangle.on.rectangle") {
            workspace.attempt {
                _ = try await workspace.createCard(body: content, in: project)
                try await workspace.services.store.deleteTask(id)
            }
        }
        if !projects.isEmpty {
            Menu("移到项目", systemImage: "folder") {
                Button("未归属") { workspace.perform { try await $0.updateTask(id) { $0.projectID = nil } } }
                    .disabled(project == nil)
                ForEach(projects) { target in
                    Button(target.name) { workspace.perform { try await $0.updateTask(id) { $0.projectID = target.id } } }
                        .disabled(target.id == project)
                }
            }
        }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { workspace.perform { try await $0.deleteTask(id) } }
    }

    @ViewBuilder private var sending: some View {
        let id = task.id, content = task.content
        #if os(macOS)
        if !services.pi.sessions.isEmpty {
            Menu("发给 Pi", systemImage: "paperplane") {
                ForEach(services.pi.sessions) { session in
                    Button(session.displayName) { sendToPi(session) }
                }
            }
        }
        Button("复制", systemImage: "doc.on.doc") { Task { await workspace.send(content, via: .clipboard, task: id) } }
        #else
        Button("发到 Mac", systemImage: "paperplane") {
            navigation.outbox = Navigation.Outbox(content: content, task: id, project: task.projectID)
        }
        Button("复制", systemImage: "doc.on.doc") {
            workspace.attempt {
                try await workspace.services.send(content, to: .clipboard, task: id)
                workspace.say("已复制")
            }
        }
        #endif
    }

    #if os(macOS)
    /// 发出后把任务关联到该会话，之后任务行显示会话状态。
    private func sendToPi(_ session: CuePi.PiSession) {
        let id = task.id, sessionID = session.sessionID
        Task {
            guard await workspace.send(task.content, via: .pi(session.id, .send), task: id) else { return }
            workspace.perform { try await $0.updateTask(id) { $0.piSessionID = sessionID } }
        }
    }
    #endif
}
