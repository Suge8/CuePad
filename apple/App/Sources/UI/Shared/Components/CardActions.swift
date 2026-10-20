import CueStore
import SwiftUI

/// 灵感与任务的菜单（长按 / Mac 右键，或任务页与纸页的"⋯"），iOS 与 Mac 共用：有哪几项、什么顺序只在 `CardMenu`，这里只画。
struct CardActions: View {
    let card: Card
    /// "⋯"里的那一份（`CardMenu.more`）；false 是长按菜单。
    var more = false
    /// 在能批量选择的地方（Mac 项目页的墙与列表）：菜单里多一项"选择"。
    var selectable = false
    /// 这是 Mac 上的叶子任务（没有步骤）：没做完时多一项"绑定会话"（会话列表在 Mac 上，手机不传）。
    var leaf = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let sections = more ? CardMenu.more(for: card) : CardMenu.sections(for: card, selectable: selectable, bindsSession: leaf)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self, content: item)
        }
    }

    @ViewBuilder private func item(_ item: CardMenu.Item) -> some View {
        switch item {
        case .move: moveMenu
        case .bindSession:
            #if os(macOS)
            Menu(item.title, icon: item.icon) { SessionBindItems(leaf: card) }
            #endif
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
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: .top(project: project.id), after: nil) } }
                    .disabled(card.parentID == nil && project.id == here)
            }
        }
    }
}

/// 每一项的字、图标与颜色语义：长按菜单、"⋯"与轻扫共用一份。
extension CardMenu.Item {
    var title: String {
        switch self {
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
        case .select: "选择"
        case .bindSession: "绑定会话"
        case .indent: "缩进"
        case .outdent: "反缩进"
        }
    }

    var icon: Icon {
        switch self {
        case .makeTask: .task
        case .makeIdea: .idea
        case .complete: .complete
        case .reopen: .reopen
        case .move: .folder
        case .archive: .archive
        case .resource: .resource
        case .unresource: .isResource
        case .copy: .copy
        case .trash: .trash
        case .select: .complete
        case .bindSession: .link
        case .indent: .indent
        case .outdent: .outdent
        }
    }

    var tone: ActionTone {
        switch self {
        case .trash: .destructive
        default: .neutral
        }
    }
}

extension CardMenu.Item {
    /// 这一项对 `card` 做什么，菜单、"⋯"与轻扫都按它执行；子菜单（移到项目、绑定会话）与此处做不了的（手机上的选择、
    /// 不在大纲里的缩进）为 nil。`structure` 是它在任务大纲里此刻能不能缩进、反缩进。
    func run(on card: Card, in workspace: Workspace, structure: TaskStructure? = nil) -> (() -> Void)? {
        let id = card.id
        switch self {
        case .makeTask, .makeIdea:
            let todo = self == .makeTask
            return { workspace.attempt { try await workspace.setTodo(id, todo) } }
        case .complete, .reopen: return { workspace.attempt { try await workspace.toggle(id) } }
        case .archive: return { workspace.attempt { try await workspace.archive(id) } }
        case .resource, .unresource:
            let pinned = self == .resource
            return { workspace.perform { try await $0.updateCard(id) { $0.isPinned = pinned } } }
        case .copy: return { workspace.copy(Outgoing.text(of: card)) }
        case .trash: return { workspace.attempt { try await workspace.trash(id) } }
        case .select:
            #if os(macOS)
            return { workspace.presses.toggle(id) }
            #else
            return nil
            #endif
        case .indent: return structure?.indent
        case .outdent: return structure?.outdent
        case .move, .bindSession: return nil
        }
    }

    /// 轻扫露出的这一项（也是同源的读屏动作）。
    func rowAction(on card: Card, in workspace: Workspace, structure: TaskStructure? = nil) -> RowAction? {
        run(on: card, in: workspace, structure: structure).map { RowAction(title, icon: icon, tone: tone, run: $0) }
    }
}

extension RowSwipes {
    /// 一条灵感或任务的轻扫（`CardMenu.swipes`）；`structure` 是它在任务大纲里此刻能不能缩进、反缩进。
    static func card(_ card: Card, workspace: Workspace, structure: TaskStructure? = nil) -> RowSwipes {
        let swipes = CardMenu.swipes(for: card, indent: structure?.indent != nil, outdent: structure?.outdent != nil)
        let action = { (item: CardMenu.Item) in item.rowAction(on: card, in: workspace, structure: structure) }
        return RowSwipes(leading: swipes.leading.compactMap(action), trailing: swipes.trailing.compactMap(action))
    }
}
