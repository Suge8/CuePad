import CueStore
import SwiftUI

/// 灵感与任务的长按（Mac 右键）菜单，iOS 与 Mac 共用：有哪几项、什么顺序只在 `CardMenu`，这里只画。
/// 交给 Agent 是平台各自的：Mac 发给当前目标（发给 Pi 会话时把任务关联到它），iOS 先选会话。
struct CardActions: View {
    let card: Card
    var inEditor = false
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let sections = CardMenu.sections(for: card, inEditor: inEditor)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self, content: item)
        }
    }

    @ViewBuilder private func item(_ item: CardMenu.Item) -> some View {
        let id = card.id
        switch item {
        case .handToAgent: handToAgent
        case .start: Button("开始", systemImage: "play") { workspace.attempt { try await workspace.start(card) } }
        case .backToTodo: Button("回到待办", systemImage: "pause") { workspace.attempt { try await workspace.start(card, back: true) } }
        case .todo: Button("要做", systemImage: "checklist") { workspace.toggleTodo(id, true) }
        case .untodo: Button("取消要做", systemImage: "lightbulb") { workspace.toggleTodo(id, false) }
        case .pin, .unpin:
            Button(item == .pin ? "置顶" : "取消置顶", systemImage: item == .pin ? "pin" : "pin.slash") {
                workspace.perform { try await $0.updateCard(id) { $0.isPinned = item == .pin } }
            }
        case .move: moveMenu
        case .trash:
            Button("移进回收站", systemImage: "trash", role: .destructive) {
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
            Button("未归档") { workspace.perform { try await $0.moveCard(id, to: .top(project: nil), after: nil) } }
                .disabled(card.parentID == nil && here == nil)
        }
    }

    @ViewBuilder private var handToAgent: some View {
        let text = Outgoing.text(of: card), id = card.id
        #if os(macOS)
        let choice = workspace.effectiveChoice(for: card.projectID)
        workspace.sendButton(choice) { Task { await workspace.send(text, via: choice, card: id) } }
        #else
        Button("交给 Agent", systemImage: "paperplane") {
            navigation.outbox = Navigation.Outbox(content: text, card: id, project: card.projectID)
        }
        #endif
    }
}
