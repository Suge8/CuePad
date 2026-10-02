import CueStore
import SwiftUI

/// 任务操作（Mac 右键、iOS 长按共用），顺序与卡片操作一致：编辑、复制与发送、转为卡片、移到项目、删除。
/// 编辑：行能就地编辑时（Mac）由行提供，否则弹出整窗的编辑框（`Workspace.editingTask`，宿主是 `CatalogGate`）。
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
        Button("编辑", systemImage: "pencil") {
            if let edit { edit() } else { workspace.editingTask = task }
        }
        Divider()
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
    /// 发给 Pi 会话后把任务关联到该会话，之后任务行显示会话状态。
    private func send(via choice: AppServices.Destination) {
        let id = task.id, content = task.content
        let sessionID: String? = if case .pi(let session, _) = choice { workspace.session(session)?.sessionID } else { nil }
        Task {
            guard await workspace.send(content, via: choice, task: id), let sessionID else { return }
            workspace.perform { try await $0.updateTask(id) { $0.piSessionID = sessionID } }
        }
    }
    #endif
}

/// 整窗的任务编辑框：行不能就地编辑时（iOS），任务菜单的"编辑"在这里改内容。
struct TaskEditor: ViewModifier {
    @Environment(Workspace.self) private var workspace
    /// 打开时记下的任务：弹框关闭会先清空 `editingTask`，保存不能依赖它
    @State private var target: CueTask?
    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert("编辑任务", isPresented: presented) {
            TextField("任务", text: $draft)
            Button("取消", role: .cancel) {}
            Button("保存", action: save)
        }
        .onChange(of: workspace.editingTask?.id) {
            guard let task = workspace.editingTask else { return }
            target = task
            draft = task.content
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { workspace.editingTask != nil }, set: { if !$0 { workspace.editingTask = nil } })
    }

    private func save() {
        guard let task = target else { return }
        let id = task.id, content = draft.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, content != task.content else { return }
        workspace.perform { try await $0.updateTask(id) { $0.content = content } }
    }
}
