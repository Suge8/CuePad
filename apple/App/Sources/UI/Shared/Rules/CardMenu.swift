import CueStore
import CueText

/// 灵感与任务的菜单有哪几项、按什么顺序（iOS 与 Mac 同一份，`CardActions` 照着画）。
/// 长按（Mac 右键）最多四项加删除：主动线是 记下 → 交给 Agent → 完成并归档，所以交给 Agent 排第一，删除单独在最后。
/// 打开是点按、完成是点圆圈、缩进是轻扫和拖放，这些不进菜单；低频的（换项目、发出记录、复制、改回灵感、资料）在浮窗与纸页的"⋯"里（`more`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case handToAgent, makeTask, makeIdea, complete, reopen, move, archive, resource, unresource, sends, copy, trash
    }

    /// 长按菜单，组间画分隔线。
    static func sections(for card: Card) -> [[Item]] {
        switch card.status {
        case nil: [[.handToAgent, .makeTask, .move, .archive], [.trash]]
        case .done: [[.handToAgent, .reopen, .archive], [.trash]]
        case .todo, .inProgress: [[.handToAgent, .complete, .archive], [.trash]]
        }
    }

    /// 浮窗（任务）与纸页（灵感）的"⋯"：交给 Agent 是页面上的主按钮，不在这里。子任务跟着上级走，不单独换项目。
    static func more(for card: Card) -> [[Item]] {
        guard card.isTask else { return [[.makeTask, card.isPinned ? .unresource : .resource, .move, .copy], [.archive], [.trash]] }
        return [(card.parentID == nil ? [.move] : []) + [.sends, .copy], [.makeIdea, .archive], [.trash]]
    }
}

/// 任务行尾的轻提示：给 Agent 的话写没写、交没交出去。只有标题时什么都不标。
nonisolated enum PromptMark: Equatable, Sendable {
    case none, written, handedOff

    init(_ card: Card) {
        if card.piSessionID != nil {
            self = .handedOff
        } else {
            self = TaskPrompt.isWritten(card.body) ? .written : .none
        }
    }

    /// 读屏里跟在任务名后面的一句。
    var speech: String? {
        switch self {
        case .none: nil
        case .written: "写了给 Agent 的话"
        case .handedOff: "交给过 Agent"
        }
    }
}

/// 任务正文就是给 Agent 的话：第一行是标题，之后的文字或图片是要求。
nonisolated enum TaskPrompt {
    static func isWritten(_ body: String) -> Bool {
        !CueSummary(body).preview.isEmpty || !CueFormat.imageHashes(in: body).isEmpty
    }
}
