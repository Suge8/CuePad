import CueStore
import CueText

/// 长按（Mac 右键）菜单里有哪几项、按什么顺序：只放没有手势的高频操作，按用得多少排，危险项单独一组在最后。
/// 打开是点按、完成是点圆圈、缩进与反缩进是轻扫和拖放（读屏另有动作），所以这些不进菜单。灵感最常做的是交给 Agent，排第一；
/// 任务换项目在浮窗的项目胶囊里（子任务跟着上级走），菜单里换成"创建灵感"——在这条任务下记一条。iOS 与 Mac 都按这里画（`CardActions`）。
nonisolated enum CardMenu {
    enum Item: Hashable, Sendable {
        case handToAgent, start, backToTodo, newIdea, todo, untodo, resource, unresource, move, trash
    }

    /// 组间画分隔线。`inEditor`：纸页的"⋯"里交给 Agent 已在菜单上方，不重复。
    static func sections(for card: Card, inEditor: Bool = false) -> [[Item]] {
        let send: [Item] = inEditor ? [] : [.handToAgent]
        let main: [Item] = switch card.status {
        case .todo: send + [.start, .newIdea, .untodo]
        case .inProgress: send + [.backToTodo, .newIdea, .untodo]
        case .done: send + [.newIdea, .untodo]
        case nil: send + [.todo, card.isPinned ? .unresource : .resource, .move]
        }
        return [main, [.trash]]
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
