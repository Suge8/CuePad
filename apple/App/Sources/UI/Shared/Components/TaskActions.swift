import CueStore
import SwiftUI

/// 任务操作（Mac 右键、iOS 长按共用）：打开、缩进与反缩进（在大纲里、做得了时）、开始（进行中的是回到待办）、交给 Agent 与复制、
/// 移到项目、取消要做（回到灵感）、移进回收站。打开由调用方提供（`open`，打开任务浮窗）；不传时没有"打开"。
/// 发送是平台各自的：Mac 发给当前目标（发给 Pi 会话时把任务关联到它），iOS 发到 Mac。
struct TaskActions: View {
    let task: Card
    var open: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.taskStructure) private var structure
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let id = task.id, project = task.projectID
        if let open {
            Button("打开", systemImage: "square.and.pencil", action: open)
            Divider()
        }
        if let indent = structure?.indent { Button("缩进", systemImage: "increase.indent", action: indent) }
        if let outdent = structure?.outdent { Button("反缩进", systemImage: "decrease.indent", action: outdent) }
        switch task.status {
        case .todo: Button("开始", systemImage: "play") { workspace.attempt { try await workspace.start(task) } }
        case .inProgress: Button("回到待办", systemImage: "pause") { workspace.attempt { try await workspace.start(task, back: true) } }
        case .done, nil: EmptyView()
        }
        sending
        Menu("移到项目", systemImage: "folder") {
            ForEach(workspace.catalog?.projects ?? []) { target in
                Button(target.name) { workspace.perform { try await $0.moveCard(id, to: .top(project: target.id), after: nil) } }
                    .disabled(target.id == project && task.parentID == nil)
            }
            Button("未归档") { workspace.perform { try await $0.moveCard(id, to: .top(project: nil), after: nil) } }
                .disabled(project == nil && task.parentID == nil)
        }
        Button("取消要做", systemImage: "lightbulb") { workspace.toggleTodo(id, false) }
        Divider()
        Button("移进回收站", systemImage: "trash", role: .destructive) { workspace.perform { try await $0.trashCard(id) } }
    }

    @ViewBuilder private var sending: some View {
        let id = task.id, content = Outgoing.text(of: task)
        #if os(macOS)
        Button("复制", systemImage: "doc.on.doc") { Task { await workspace.send(content, via: .clipboard, card: id) } }
        let choice = workspace.effectiveChoice(for: task.projectID)
        workspace.sendButton(choice) { Task { await workspace.send(content, via: choice, card: id) } }
        #else
        Button("复制", systemImage: "doc.on.doc") {
            workspace.attempt {
                try await workspace.services.send(content, to: .clipboard, card: id)
                workspace.say("已复制")
            }
        }
        Button("交给 Agent", systemImage: "paperplane") {
            navigation.outbox = Navigation.Outbox(content: content, card: id, project: task.projectID)
        }
        #endif
    }
}

/// 子任务进度与完成上级时的确认（Mac 与 iOS 同一套）。
enum TaskCopy {
    static func progress(_ subtasks: TaskProgress) -> String { "子任务 \(subtasks.done)/\(subtasks.total)" }
    static func hasOpen(_ subtasks: TaskProgress?) -> Bool { subtasks.map { $0.done < $0.total } ?? false }
    static func openSubtasks(_ subtasks: TaskProgress?) -> String {
        "还有 \(subtasks.map { $0.total - $0.done } ?? 0) 个子任务没完成，一起完成？"
    }
}

/// 任务行给读屏的文案（Mac 与 iOS 同一套）：整行一个元素，标签是任务内容，值是状态，默认动作切换完成。
enum TaskSpeech {
    static func value(_ status: TaskStatus?) -> String {
        switch status {
        case .todo: "待办"
        case .inProgress: "进行中"
        case .done: "已完成"
        case nil: "灵感"
        }
    }

    static func value(done: Bool) -> String { done ? "已完成" : "未完成" }
    static func toggle(done: Bool) -> String { done ? "标为未完成" : "标为完成" }
}
