import CueStore

/// 一条卡能做什么、菜单有哪几项、按什么顺序（iOS 与 Mac 同一份，`CardActions` 照着画）。
/// 动线是任务优先：记下灵感 → 挂到任务（成为提示词）→ 在提示词上交给 Agent → 完成并归档。所以灵感的主动作是挂到任务，
/// 交给 Agent 只在提示词上（`handsToAgent`）；任务本身没有话可交。长按（Mac 右键）最多四项加删除，主动作排第一，删除单独在最后；
/// 打开是点按、完成是点圆圈、缩进是轻扫和拖放，这些不进菜单；低频的（换项目、复制、改回灵感、资料）在任务页与纸页的"⋯"里（`more`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case attachToTask, handToAgent, makeTask, makeIdea, complete, reopen, move, archive, resource, unresource, copy, trash
    }

    /// 能不能交给 Agent：只有提示词（挂在任务下的灵感）能。灵感先挂到任务，任务本身没有话可交。
    static func handsToAgent(_ card: Card) -> Bool { !card.isTask && card.parentID != nil }

    /// 长按菜单，组间画分隔线。
    static func sections(for card: Card) -> [[Item]] {
        switch card.status {
        case nil: [[handsToAgent(card) ? .handToAgent : .attachToTask, .makeTask, .move, .archive], [.trash]]
        case .done: [[.reopen, .archive], [.trash]]
        case .todo, .inProgress: [[.complete, .archive], [.trash]]
        }
    }

    /// 任务页与纸页的"⋯"。提示词已经挂在任务下，不再"挂到任务"；交给 Agent 在页面上（提示词卡与提示词的纸页），不在这里。
    /// 子任务跟着上级走，不单独换项目。
    static func more(for card: Card) -> [[Item]] {
        guard card.isTask else {
            let attach: [Item] = handsToAgent(card) ? [] : [.attachToTask]
            return [attach + [.makeTask, card.isPinned ? .unresource : .resource, .move, .copy], [.archive], [.trash]]
        }
        return [(card.parentID == nil ? [.move] : []) + [.copy], [.makeIdea, .archive], [.trash]]
    }
}
