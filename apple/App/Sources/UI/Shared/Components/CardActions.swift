import CueStore
import SwiftUI

/// 灵感与任务的菜单（长按 / Mac 右键，或任务页与纸页的"⋯"），iOS 与 Mac 共用：有哪几项、什么顺序只在 `CardMenu`，这里只画。
/// 挂到任务两端一样（弹出选任务的面板，`Workspace.attaching`）；交给 Agent（只在提示词上）是平台各自的：
/// Mac 发给当前目标（发给 Pi 会话时把提示词关联到它），iOS 浮起交给 Agent 的输入框。
struct CardActions: View {
    let card: Card
    /// "⋯"里的那一份（`CardMenu.more`）；false 是长按菜单。
    var more = false
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let sections = more ? CardMenu.more(for: card) : CardMenu.sections(for: card)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self, content: item)
        }
    }

    @ViewBuilder private func item(_ item: CardMenu.Item) -> some View {
        let id = card.id
        switch item {
        case .attachToTask: Button("挂到任务…", systemImage: "checkmark") { workspace.attaching = card }
        case .handToAgent: handToAgent
        case .makeTask: Button("设为任务", systemImage: "checklist") { workspace.toggleTodo(id, true) }
        case .makeIdea: Button("改回灵感", systemImage: "lightbulb") { workspace.toggleTodo(id, false) }
        case .complete, .reopen:
            Button(item == .complete ? "完成" : "重新打开", systemImage: item == .complete ? "checkmark.circle" : "arrow.uturn.backward.circle") {
                let task = card
                workspace.attempt { try await workspace.toggle(task) }
            }
        case .archive: Button("归档", systemImage: "archivebox") { workspace.attempt { try await workspace.archive(id) } }
        case .resource, .unresource:
            Button(item == .resource ? "设为资料" : "不再是资料", systemImage: item == .resource ? "books.vertical" : "books.vertical.fill") {
                workspace.perform { try await $0.updateCard(id) { $0.isPinned = item == .resource } }
            }
        case .move: moveMenu
        case .copy: copy
        case .trash:
            Button("删除", systemImage: "trash", role: .destructive) {
                if workspace.openCard == id { workspace.openCard = nil }
                workspace.perform { try await $0.trashCard(id) }
            }
        }
    }

    private var moveMenu: some View {
        let id = card.id, here = card.parentID == nil ? card.projectID : nil
        return Menu("移到项目", systemImage: "folder") {
            ForEach(workspace.catalog?.projects ?? []) { project in
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: .top(project: project.id), after: nil) } }
                    .disabled(card.parentID == nil && project.id == here)
            }
            Button(CaptureCopy.inbox) { workspace.perform { try await $0.moveCard(id, to: .top(project: nil), after: nil) } }
                .disabled(card.parentID == nil && here == nil)
        }
    }

    private var copy: some View {
        Button("复制", systemImage: "doc.on.doc") { workspace.copy(Outgoing.text(of: card)) }
    }

    @ViewBuilder private var handToAgent: some View {
        #if os(macOS)
        let text = Outgoing.text(of: card), id = card.id
        workspace.sendButton(workspace.agentTarget(for: card.projectID)) { target in Task { await workspace.send(text, to: target, card: id) } }
        #else
        Button("交给 Agent", systemImage: "paperplane") { navigation.handToAgent(card) }
        #endif
    }
}
