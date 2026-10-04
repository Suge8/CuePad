import CueStore
import SwiftUI

/// 任务操作（Mac 右键、iOS 长按共用），顺序与卡片操作一致：编辑、复制与发送、转为卡片、移到项目、删除。
/// 编辑由调用方提供（`edit`）：菜单收起后菜单所在的行就没了，编辑框或就地编辑由行所在的视图持有；不传时没有"编辑"。
/// 发送是平台各自的：Mac 发给当前目标（发给 Pi 会话时把任务关联到它），iOS 发到 Mac。
struct TaskActions: View {
    let task: CueTask
    var edit: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let id = task.id, content = task.content, project = task.projectID
        if let edit {
            Button("编辑", systemImage: "pencil", action: edit)
            Divider()
        }
        sending
        Button("转为卡片", systemImage: "rectangle.on.rectangle") {
            workspace.attempt {
                _ = try await workspace.createCard(body: content, in: project)
                try await workspace.services.store.deleteTask(id)
            }
        }
        Menu("移到项目", systemImage: "folder") {
            ForEach(workspace.catalog?.projects ?? []) { target in
                Button(target.name) { workspace.perform { try await $0.updateTask(id) { $0.projectID = target.id } } }
                    .disabled(target.id == project)
            }
            Button("未归档") { workspace.perform { try await $0.updateTask(id) { $0.projectID = nil } } }
                .disabled(project == nil)
        }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { workspace.perform { try await $0.deleteTask(id) } }
    }

    @ViewBuilder private var sending: some View {
        let id = task.id, content = task.content
        #if os(macOS)
        Button("复制", systemImage: "doc.on.doc") { Task { await workspace.send(content, via: .clipboard, task: id) } }
        let choice = workspace.effectiveChoice(for: task.projectID)
        workspace.sendButton(choice) { send(via: choice) }
        #else
        Button("复制", systemImage: "doc.on.doc") {
            workspace.attempt {
                try await workspace.services.send(content, to: .clipboard, task: id)
                workspace.say("已复制")
            }
        }
        Button("发到 Mac", systemImage: "paperplane") {
            navigation.outbox = Navigation.Outbox(content: content, task: id, project: task.projectID)
        }
        #endif
    }

    #if os(macOS)
    /// 发给 Pi 会话时，执行投送的那台 Mac 记发送记录的同时把任务关联到该会话（之后任务行显示会话状态）。
    private func send(via choice: AppServices.Destination) {
        let id = task.id, content = task.content
        Task { await workspace.send(content, via: choice, task: id) }
    }
    #endif
}

/// 任务行给读屏的文案（Mac 与 iOS 同一套）：整行一个元素，标签是任务内容，值是完成状态，默认动作切换完成。
enum TaskSpeech {
    static func value(done: Bool) -> String { done ? "已完成" : "未完成" }
    static func toggle(done: Bool) -> String { done ? "标为未完成" : "标为完成" }
}
