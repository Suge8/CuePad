import CueStore

/// 一条卡能做什么、菜单有哪几项、按什么顺序（iOS 与 Mac 同一份，`CardActions` 照着画）。
/// 动线是任务优先：建任务（标题下面写要交代的话）→ 开始（正文作为第一句交给 Agent，见 `TaskNext`）→ 完成并归档。
/// 灵感与任务不互转：灵感要做，就拖到一条任务上接进它的正文（`Workspace.mergeIdea`）。
/// 长按（Mac 右键）最多四项加删除，删除单独在最后；手机上的任务行不挂长按菜单（长按是拖动，见 `TaskLine`），其余操作在左滑的"更多"里（`more`），
/// 看板的卡挂（按住不动出菜单，菜单出来后往菜单外一挪是拖，`BoardTaskCard`）；点一下进的是会话的任务（`Workspace.entersSession`），菜单第一项是"打开任务"（`open`）；
/// 打开是点按、完成是点圆圈、缩进是轻扫和拖放，这些不进菜单；低频的（换项目、复制、置顶）在任务气泡与纸页的"⋯"里（`more(for:)`）。
/// 一行轻扫露出的动作也在这里（`swipes`）。删除只有一处（`Workspace.trash`，进回收站、提示里可撤销）：菜单、轻扫之外，
/// Mac 上悬停墙上的卡与"更早"的行时露出删除钮，⌘⌫ 删鼠标停着的那张（`DeleteCardButton`、`CardPresses.deletable`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case complete, reopen, move, archive, pin, unpin, copy, trash
        /// 手机任务行左滑的"⋯ 更多"：从这一下长出这条任务的其余操作（`CardMorePanel`、`swipeMore`）。
        case more
        /// 打开任务气泡：点一下进的是会话时，长按菜单的第一项。
        case open
        /// 开始批量选择（Mac 项目页上散放的灵感）。
        case select
        /// 给没做完的叶子任务绑定、改绑、解除 Agent 会话（Mac 的右键；会话列表在 Mac 上）。
        case bindSession
        /// 任务在大纲里缩进、反缩进：缩进在右滑里，两样都在读屏动作里（`taskSpoken`；看得见的反缩进是拖放）。
        case indent, outdent
    }

    /// 一行两边轻扫露出的动作，排在前面的在最外侧、一滑到底执行它。
    struct Swipes: Equatable, Sendable {
        var leading: [Item]
        var trailing: [Item]
    }

    /// 轻扫：任务右滑缩进（大纲里此刻能缩进时）、左滑删除与"更多"；灵感左滑删除。删除在最外侧，一滑到底就是它。
    static func swipes(for card: Card, indent: Bool) -> Swipes {
        guard card.isTask else { return Swipes(leading: [], trailing: [.trash]) }
        return Swipes(leading: indent ? [.indent] : [], trailing: [.trash, .more])
    }

    /// 左滑"更多"长出的气泡里的那几项（`CardMorePanel`）：点它进的是会话时（`opens`，同 `sections`）先是"打开任务"，再是完成或重新打开、复制、归档；
    /// 换项目另起一行翻页，子任务跟着上级走、没有这一行。
    static func swipeMore(for card: Card, opens: Bool) -> [Item] {
        (opens ? [.open] : []) + [card.status == .done ? .reopen : .complete, .copy, .archive]
    }

    /// 长按菜单，组间画分隔线。`selectable`：这张卡在能批量选择的地方（Mac 项目页的墙与列表），删除前多一项"选择"。
    /// `bindsSession`：这是 Mac 上的叶子任务（没有子任务），没做完时多一项"绑定会话"。
    /// `opens`：点它进的是会话（`Workspace.entersSession`），最前面单独一组"打开任务"；点一下就是打开任务的不重复这一项。
    /// 没做完的任务：完成与归档一组，绑定会话一组（Mac 的叶子），删除最后；没有绑定会话时不留空组。
    static func sections(for card: Card, selectable: Bool = false, bindsSession: Bool = false, opens: Bool = false) -> [[Item]] {
        let head: [[Item]] = opens ? [[.open]] : []
        return switch card.status {
        case nil: [[.move, .archive], (selectable ? [.select] : []) + [.trash]]
        case .done: head + [[.reopen, .archive], [.trash]]
        case .todo, .inProgress: head + [[.complete, .archive], bindsSession ? [.bindSession] : [], [.trash]].filter { !$0.isEmpty }
        }
    }

    /// 任务气泡与纸页的"⋯"。子任务跟着上级走，不单独换项目。
    static func more(for card: Card) -> [[Item]] {
        guard card.isTask else { return [[card.isPinned ? .unpin : .pin, .move, .copy], [.archive], [.trash]] }
        return [(card.parentID == nil ? [.move] : []) + [.copy], [.archive], [.trash]]
    }
}
