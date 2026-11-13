import CueStore
import SwiftUI

/// 有哪几项、什么顺序只在 `CardMenu`，这里只画。
struct CardActions: View {
    let card: Card
    var more = false
    var selectable = false
    var leaf = false
    var opens = false
    var session: SessionState?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let ends = session?.canEnd == true
        let sections = more ? CardMenu.more(for: card, bindsSession: leaf) : CardMenu.sections(for: card, selectable: selectable, bindsSession: leaf, opens: opens, endsSession: ends)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self, content: item)
        }
    }

    @ViewBuilder private func item(_ item: CardMenu.Item) -> some View {
        switch item {
        case .move: moveMenu
        case .bindSession:
            Menu(item.title, icon: item.icon) { SessionBindItems(leaf: card) }
        case .endSession:
            if let session, let end = SessionActions.end(session, ending: false, in: workspace) { RowActionButtons(actions: [end]) }
        default:
            if let run = item.run(on: card, in: workspace) {
                Button(item.title, icon: item.icon, role: item.tone == .destructive ? .destructive : nil, action: run)
            }
        }
    }

    private var moveMenu: some View {
        let id = card.id, here = card.parentID == nil ? card.projectID : nil
        return Menu(CardMenu.Item.move.title, icon: CardMenu.Item.move.icon) {
            ForEach(workspace.catalog?.projects ?? []) { project in
                Button(project.shownName) { workspace.move(id, to: .top(project: project.id), after: nil) }
                    .disabled(card.parentID == nil && project.id == here)
            }
        }
    }
}

extension CardMenu.Item {
    var title: LocalizedStringResource {
        switch self {
        case .complete: "完成"
        case .reopen: "重新打开"
        case .move: "移到项目"
        case .archive: "归档"
        case .pin: "置顶"
        case .unpin: "取消置顶"
        case .copy: "复制"
        case .trash: "删除"
        case .select: "选择"
        case .bindSession: "绑定会话"
        case .indent: "缩进"
        case .outdent: "反缩进"
        case .more: "更多"
        case .open: "打开任务"
        case .endSession: "结束会话"
        }
    }

    var icon: Icon {
        switch self {
        case .complete: .complete
        case .reopen: .reopen
        case .move: .folder
        case .archive: .archive
        case .pin: .pin
        case .unpin: .unpin
        case .copy: .copy
        case .trash: .trash
        case .select: .complete
        case .bindSession: .link
        case .indent: .indent
        case .outdent: .outdent
        case .more: .more
        case .open: .task
        case .endSession: .endSession
        }
    }

    var tone: ActionTone {
        switch self {
        case .trash: .destructive
        case .more: .quiet
        default: .neutral
        }
    }
}

extension CardMenu.Item {
    /// 子菜单（移到项目、绑定会话）与此处做不了的（手机上的选择、Mac 上的"更多"、不在大纲里的缩进）为 nil。
    func run(on card: Card, in workspace: Workspace, structure: TaskStructure? = nil) -> (() -> Void)? {
        let id = card.id
        switch self {
        case .complete: return { workspace.attempt { try await workspace.complete(id) } }
        case .reopen: return { workspace.attempt { try await workspace.reopen(id) } }
        case .archive: return { workspace.attempt { try await workspace.archive(id) } }
        case .pin, .unpin:
            let pinned = self == .pin
            return { workspace.setPinned(id, pinned) }
        case .copy: return { workspace.copy(Outgoing.text(of: card)) }
        case .open: return { workspace.openTask(card) }
        case .trash: return { workspace.attempt { try await workspace.trash(id) } }
        case .select:
            #if os(macOS)
            return { workspace.presses.toggle(id) }
            #else
            return nil
            #endif
        case .indent: return structure?.indent
        case .outdent: return structure?.outdent
        case .more:
            #if os(iOS)
            return {
                let opens = workspace.agentLinks.items[card.id] != nil
                workspace.moreCard = CardMoreRequest(card: card, opens: opens, source: workspace.press.source)
            }
            #else
            return nil
            #endif
        case .move, .bindSession, .endSession: return nil
        }
    }

    func rowAction(on card: Card, in workspace: Workspace, structure: TaskStructure? = nil) -> RowAction? {
        run(on: card, in: workspace, structure: structure).map { RowAction(title, icon: icon, tone: tone, run: $0) }
    }
}

extension RowSwipes {
    static func card(_ card: Card, workspace: Workspace, structure: TaskStructure? = nil) -> RowSwipes {
        let swipes = CardMenu.swipes(for: card, indent: structure?.indent != nil)
        let action = { (item: CardMenu.Item) in item.rowAction(on: card, in: workspace, structure: structure) }
        return RowSwipes(leading: swipes.leading.compactMap(action), trailing: swipes.trailing.compactMap(action))
    }
}
