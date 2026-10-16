import CueStore

/// 一条卡能做什么、菜单有哪几项、按什么顺序（iOS 与 Mac 同一份，`CardActions` 照着画）。
/// 动线是任务优先：记下灵感 → 设为任务（标题下面写要交代的话）→ 开始（正文作为第一句交给 Agent，见 `TaskNext`）→ 完成并归档。
/// 所以灵感的主动作是设为任务。长按（Mac 右键）最多四项加删除，主动作排第一，删除单独在最后；
/// 打开是点按、完成是点圆圈、缩进是轻扫和拖放，这些不进菜单；低频的（换项目、复制、改回灵感、资料）在任务页与纸页的"⋯"里（`more`）。
/// 一行轻扫露出的动作也在这里（`swipes`）。删除只有一处（`Workspace.trash`，进回收站、提示里可撤销）：菜单、轻扫之外，
/// Mac 上悬停墙上的卡与"更早"的行时露出删除钮，⌘⌫ 删鼠标停着的那张（`DeleteCardButton`、`CardPresses.deletable`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case makeTask, makeIdea, complete, reopen, move, archive, resource, unresource, copy, trash
        /// 开始批量选择（Mac 项目页上散放的灵感）。
        case select
        /// 给没做完的叶子任务绑定、改绑、解除 Agent 会话（Mac 的右键；会话列表在 Mac 上）。
        case bindSession
        /// 只在轻扫里：任务在大纲里缩进、反缩进。
        case indent, outdent
    }

    /// 一行两边轻扫露出的动作，排在前面的在最外侧、一滑到底执行它。
    struct Swipes: Equatable, Sendable {
        var leading: [Item]
        var trailing: [Item]
    }

    /// 轻扫：任务右滑缩进、左滑删除与反缩进；灵感左滑删除与设为任务。做不了的不出现
    /// （`indent`/`outdent`：大纲里这一行此刻能不能缩进、反缩进）。
    static func swipes(for card: Card, indent: Bool, outdent: Bool) -> Swipes {
        guard card.isTask else { return Swipes(leading: [], trailing: [.trash, .makeTask]) }
        return Swipes(leading: indent ? [.indent] : [], trailing: [.trash] + (outdent ? [.outdent] : []))
    }

    /// 长按菜单，组间画分隔线。`selectable`：这张卡在能批量选择的地方（Mac 项目页的墙与列表），删除前多一项"选择"。
    /// `bindsSession`：这是 Mac 上的叶子任务（没有步骤），没做完时多一项"绑定会话"。
    /// 没做完的任务：完成与归档一组，绑定会话一组（Mac 的叶子），删除最后；没有绑定会话时不留空组。
    static func sections(for card: Card, selectable: Bool = false, bindsSession: Bool = false) -> [[Item]] {
        switch card.status {
        case nil: [[.makeTask, .move, .archive], (selectable ? [.select] : []) + [.trash]]
        case .done: [[.reopen, .archive], [.trash]]
        case .todo, .inProgress: [[.complete, .archive], bindsSession ? [.bindSession] : [], [.trash]].filter { !$0.isEmpty }
        }
    }

    /// 任务页与纸页的"⋯"。步骤跟着上级走，不单独换项目。
    static func more(for card: Card) -> [[Item]] {
        guard card.isTask else { return [[.makeTask, card.isPinned ? .unresource : .resource, .move, .copy], [.archive], [.trash]] }
        return [(card.parentID == nil ? [.move] : []) + [.copy], [.makeIdea, .archive], [.trash]]
    }
}
