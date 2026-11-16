import CueStore

/// 灵感与任务不互转，菜单里没有这一项：灵感要做，就拖到一条任务上接进它的正文，或拖到"添加任务"上照它新建一条（`Workspace.mergeIdea`、`newTask(fromIdea:)`）。
/// 手机上的任务行不挂长按菜单（长按是拖动，见 `TaskLine`），其余操作在左滑的"更多"里（`more`）；看板的卡挂（按住不动出菜单，菜单出来后往菜单外一挪是拖，`BoardTaskCard`）。
/// 删除的写入只有一处：`Workspace.trash`。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case complete, reopen, move, archive, pin, unpin, copy, trash
        case more
        case open
        case select
        case bindSession
        case indent, outdent
    }

    /// 一行两边轻扫露出的动作，排在前面的在最外侧、一滑到底执行它。
    struct Swipes: Equatable, Sendable {
        var leading: [Item]
        var trailing: [Item]
    }

    static func swipes(for card: Card, indent: Bool) -> Swipes {
        guard card.isTask else { return Swipes(leading: [], trailing: [.trash]) }
        return Swipes(leading: indent ? [.indent] : [], trailing: [.trash, .more])
    }

    static func swipeMore(for card: Card, opens: Bool) -> [Item] {
        (opens ? [.open] : []) + [card.status == .done ? .reopen : .complete] + pin(card) + [.copy, .archive]
    }

    /// 右键菜单至多三组（去哪看、整理、删除），项少：系统的指引是右键只放这个对象常用的，约三组以内。
    /// 没做完的任务不给归档（做完的提示上有，气泡的"⋯"里也有），绑定会话在任务气泡的"⋯"里（`more`），会话的休眠在会话自己的菜单里。
    /// `selectable`：这张卡在能批量选择的地方（Mac 项目页的墙与列表），删除前多一项"选择"。
    /// `opens`：点它进的是会话（`Workspace.enter`），最前面单独一组"打开任务"；点一下就是打开任务的不重复这一项。
    static func sections(for card: Card, selectable: Bool = false, opens: Bool = false) -> [[Item]] {
        let head: [[Item]] = opens ? [[.open]] : []
        return switch card.status {
        case nil: [[.move, .archive], (selectable ? [.select] : []) + [.trash]]
        case .done: head + [pin(card) + [.reopen, .archive], [.trash]]
        case .todo, .inProgress: head + [pin(card) + [.complete], [.trash]]
        }
    }

    /// 子任务跟着上级走，不单独换项目、不单独置顶。
    /// `bindsSession`：这是叶子任务（没有子任务），没做完时多一项"绑定会话"（任务气泡的"⋯"）。
    static func more(for card: Card, bindsSession: Bool = false) -> [[Item]] {
        guard card.isTask else { return [[card.isPinned ? .unpin : .pin, .move, .copy], [.archive], [.trash]] }
        let binds: [Item] = bindsSession && card.status != .done ? [.bindSession] : []
        return [[card.status == .done ? .reopen : .complete] + pin(card) + (card.parentID == nil ? [.move] : []) + [.copy], binds, [.archive], [.trash]]
            .filter { !$0.isEmpty }
    }

    private static func pin(_ task: Card) -> [Item] { task.parentID == nil ? [task.isPinned ? .unpin : .pin] : [] }
}
