import CueStore
import SwiftUI

/// 灵感与任务的菜单（长按 / Mac 右键，或浮窗与纸页的"⋯"），iOS 与 Mac 共用：有哪几项、什么顺序只在 `CardMenu`，这里只画。
/// 交给 Agent 是平台各自的：Mac 发给当前目标（发给 Pi 会话时把灵感或任务关联到它），iOS 浮起交给 Agent 的输入框。
struct CardActions: View {
    let card: Card
    /// "⋯"里的那一份（`CardMenu.more`）；false 是长按菜单。
    var more = false
    /// "发出记录"在哪打开（任务浮窗推入一页）。
    var showSends: (() -> Void)?
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
        case .sends: if let showSends { Button("发出记录", systemImage: "clock.arrow.circlepath", action: showSends) }
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

    @ViewBuilder private var copy: some View {
        let text = Outgoing.text(of: card), id = card.id
        #if os(macOS)
        Button("复制", systemImage: "doc.on.doc") { Task { await workspace.send(text, via: .clipboard, card: id) } }
        #else
        Button("复制", systemImage: "doc.on.doc") { workspace.copy(card) }
        #endif
    }

    @ViewBuilder private var handToAgent: some View {
        let text = Outgoing.text(of: card), id = card.id
        #if os(macOS)
        let choice = workspace.effectiveChoice(for: card.projectID)
        workspace.sendButton(choice) { Task { await workspace.send(text, via: choice, card: id) } }
        #else
        Button("交给 Agent", systemImage: "paperplane") { navigation.handToAgent(card) }
        #endif
    }
}
