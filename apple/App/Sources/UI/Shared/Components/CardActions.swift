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
        case .attachToTask: Button(item.title + "…", systemImage: item.symbol) { workspace.attaching = card }
        case .handToAgent: handToAgent
        case .makeTask, .makeIdea: Button(item.title, systemImage: item.symbol) { workspace.attempt { try await workspace.setTodo(id, item == .makeTask) } }
        case .complete, .reopen:
            Button(item.title, systemImage: item.symbol) {
                let task = card
                workspace.attempt { try await workspace.toggle(task) }
            }
        case .archive: Button(item.title, systemImage: item.symbol) { workspace.attempt { try await workspace.archive(id) } }
        case .resource, .unresource:
            Button(item.title, systemImage: item.symbol) {
                workspace.perform { try await $0.updateCard(id) { $0.isPinned = item == .resource } }
            }
        case .move: moveMenu
        case .copy: Button(item.title, systemImage: item.symbol) { workspace.copy(Outgoing.text(of: card)) }
        case .trash: Button(item.title, systemImage: item.symbol, role: .destructive) { workspace.attempt { try await workspace.trash(id) } }
        // 只在轻扫里（`CardMenu.swipes`）
        case .indent, .outdent: EmptyView()
        }
    }

    private var moveMenu: some View {
        let id = card.id, here = card.parentID == nil ? card.projectID : nil
        return Menu(CardMenu.Item.move.title, systemImage: CardMenu.Item.move.symbol) {
            ForEach(workspace.catalog?.projects ?? []) { project in
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: .top(project: project.id), after: nil) } }
                    .disabled(card.parentID == nil && project.id == here)
            }
            Button(CaptureCopy.unfiled) { workspace.perform { try await $0.moveCard(id, to: .top(project: nil), after: nil) } }
                .disabled(card.parentID == nil && here == nil)
        }
    }

    @ViewBuilder private var handToAgent: some View {
        #if os(macOS)
        let text = Outgoing.text(of: card), id = card.id
        workspace.sendButton(workspace.sendState.agentTarget(for: card.projectID)) { target in Task { await workspace.send(text, to: target, card: id) } }
        #else
        Button(CardMenu.Item.handToAgent.title, systemImage: CardMenu.Item.handToAgent.symbol) { navigation.handToAgent(card) }
        #endif
    }
}

/// 每一项的字、图标与颜色语义：长按菜单、"⋯"与轻扫共用一份。
extension CardMenu.Item {
    var title: String {
        switch self {
        case .attachToTask: "挂到任务"
        case .handToAgent: "交给 Agent"
        case .makeTask: "设为任务"
        case .makeIdea: "改回灵感"
        case .complete: "完成"
        case .reopen: "重新打开"
        case .move: "移到项目"
        case .archive: "归档"
        case .resource: "设为资料"
        case .unresource: "不再是资料"
        case .copy: "复制"
        case .trash: "删除"
        case .indent: "缩进"
        case .outdent: "反缩进"
        }
    }

    var symbol: String {
        switch self {
        // 挂进任务成为它下面的一条，不用对勾：对勾读作"完成、存好"，只给"记下"这类提交（`SubmitGlyph`）
        case .attachToTask: "arrow.turn.down.right"
        case .handToAgent: "paperplane"
        case .makeTask: "checklist"
        case .makeIdea: "lightbulb"
        case .complete: "checkmark.circle"
        case .reopen: "arrow.uturn.backward.circle"
        case .move: "folder"
        case .archive: "archivebox"
        case .resource: "books.vertical"
        case .unresource: "books.vertical.fill"
        case .copy: "doc.on.doc"
        case .trash: "trash"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        }
    }

    var tone: ActionTone {
        switch self {
        case .trash: .destructive
        case .attachToTask, .handToAgent: .primary
        default: .neutral
        }
    }
}

extension RowSwipes {
    /// 一条灵感或任务的轻扫（`CardMenu.swipes`）；`structure` 是它在任务大纲里此刻能不能缩进、反缩进。
    static func card(_ card: Card, workspace: Workspace, structure: TaskStructure? = nil) -> RowSwipes {
        let swipes = CardMenu.swipes(for: card, indent: structure?.indent != nil, outdent: structure?.outdent != nil)
        func action(_ item: CardMenu.Item) -> RowAction? {
            let run: (() -> Void)? = switch item {
            case .attachToTask: { workspace.attaching = card }
            case .makeTask: { workspace.attempt { try await workspace.setTodo(card.id, true) } }
            case .trash: { workspace.attempt { try await workspace.trash(card.id) } }
            case .indent: structure?.indent
            case .outdent: structure?.outdent
            // 不在轻扫里（`CardMenu.swipes` 不给）
            default: nil
            }
            return run.map { RowAction(item.title, symbol: item.symbol, tone: item.tone, run: $0) }
        }
        return RowSwipes(leading: swipes.leading.compactMap(action), trailing: swipes.trailing.compactMap(action))
    }
}
