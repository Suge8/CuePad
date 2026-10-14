import CueStore

/// 一条卡能做什么、菜单有哪几项、按什么顺序（iOS 与 Mac 同一份，`CardActions` 照着画）。
/// 动线是任务优先：记下灵感 → 挂到任务（成为提示词）→ 在提示词上发给 Agent → 完成并归档。所以灵感的主动作是挂到任务，
/// 发给 Agent 只在提示词上（`handsToAgent`）；任务本身没有话可交。长按（Mac 右键）最多四项加删除，主动作排第一，删除单独在最后；
/// 打开是点按、完成是点圆圈、缩进是轻扫和拖放，这些不进菜单；低频的（换项目、复制、改回灵感、资料）在任务页与纸页的"⋯"里（`more`）。
/// 一行轻扫露出的动作也在这里（`swipes`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case attachToTask, handToAgent, makeTask, makeIdea, complete, reopen, move, archive, resource, unresource, copy, trash
        /// 交给 Cue 跟进、收回自己做：只在没做完的顶层任务上（`Card.cueFollows`）。
        case cueFollow, cueRelease
        /// 开始批量选择（Mac 项目页上散放的灵感）。
        case select
        /// 只在轻扫里：任务在大纲里缩进、反缩进。
        case indent, outdent
    }

    /// 一行两边轻扫露出的动作，排在前面的在最外侧、一滑到底执行它。
    struct Swipes: Equatable, Sendable {
        var leading: [Item]
        var trailing: [Item]
    }

    /// 轻扫：任务右滑缩进、左滑删除与反缩进；灵感右滑挂到任务、左滑删除与设为任务。做不了的不出现
    /// （`indent`/`outdent`：大纲里这一行此刻能不能缩进、反缩进）。提示词不在轻扫里挂到任务（已挂着），发给 Agent 在提示词卡上。
    static func swipes(for card: Card, indent: Bool, outdent: Bool) -> Swipes {
        guard card.isTask else { return Swipes(leading: handsToAgent(card) ? [] : [.attachToTask], trailing: [.trash, .makeTask]) }
        return Swipes(leading: indent ? [.indent] : [], trailing: [.trash] + (outdent ? [.outdent] : []))
    }

    /// 能不能发给 Agent：只有提示词（挂在任务下的灵感）能。灵感先挂到任务，任务本身没有话可交。
    static func handsToAgent(_ card: Card) -> Bool { !card.isTask && card.parentID != nil }

    /// 长按菜单，组间画分隔线。`selectable`：这张卡在能批量选择的地方（Mac 项目页的墙与列表），删除前多一项"选择"。
    static func sections(for card: Card, selectable: Bool = false) -> [[Item]] {
        switch card.status {
        case nil: [[handsToAgent(card) ? .handToAgent : .attachToTask, .makeTask, .move, .archive], (selectable ? [.select] : []) + [.trash]]
        case .done: [[.reopen, .archive], [.trash]]
        case .todo, .inProgress: [[.complete] + cueItem(card) + [.archive], [.trash]]
        }
    }

    static func cueItem(_ card: Card) -> [Item] {
        guard card.parentID == nil, card.isTask, card.status != .done else { return [] }
        return [card.cueFollows ? .cueRelease : .cueFollow]
    }

    /// 任务页与纸页的"⋯"。提示词已经挂在任务下，不再"挂到任务"；发给 Agent 在页面上（提示词卡与提示词的纸页），不在这里。
    /// 步骤跟着上级走，不单独换项目。
    static func more(for card: Card) -> [[Item]] {
        guard card.isTask else {
            let attach: [Item] = handsToAgent(card) ? [] : [.attachToTask]
            return [attach + [.makeTask, card.isPinned ? .unresource : .resource, .move, .copy], [.archive], [.trash]]
        }
        return [cueItem(card) + (card.parentID == nil ? [.move] : []) + [.copy], [.makeIdea, .archive], [.trash]]
    }
}
