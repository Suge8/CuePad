import CueStore
import CueText

/// 灵感与任务的菜单有哪几项、按什么顺序（iOS 与 Mac 同一份，`CardActions` 照着画）。
/// 长按（Mac 右键）最多四项加删除：主动线是 记下 → 交给 Agent → 完成并归档，所以灵感的交给 Agent 排第一，删除单独在最后。
/// 任务本身没有话可交：交给 Agent 在它的每条提示词上（任务页）。打开是点按、完成是点圆圈、缩进是轻扫和拖放，这些不进菜单；
/// 低频的（换项目、复制、改回灵感、资料）在任务页与纸页的"⋯"里（`more`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case handToAgent, makeTask, makeIdea, complete, reopen, move, archive, resource, unresource, copy, trash
    }

    /// 长按菜单，组间画分隔线。
    static func sections(for card: Card) -> [[Item]] {
        switch card.status {
        case nil: [[.handToAgent, .makeTask, .move, .archive], [.trash]]
        case .done: [[.reopen, .archive], [.trash]]
        case .todo, .inProgress: [[.complete, .archive], [.trash]]
        }
    }

    /// 任务页与纸页（灵感）的"⋯"：交给 Agent 在页面上（灵感右下、提示词卡上），不在这里。子任务跟着上级走，不单独换项目。
    static func more(for card: Card) -> [[Item]] {
        guard card.isTask else { return [[.makeTask, card.isPinned ? .unresource : .resource, .move, .copy], [.archive], [.trash]] }
        return [(card.parentID == nil ? [.move] : []) + [.copy], [.makeIdea, .archive], [.trash]]
    }
}
