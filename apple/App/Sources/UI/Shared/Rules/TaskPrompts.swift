import CueStore

/// 任务行上的提示词计数："3 条提示词 · 1 已回复"（全部回复了写"全部已回复"）；没有提示词时不写。
/// 全部提示词都已回复、任务还没完成时，行尾给一颗"完成"——任务不自动完成，由用户确认。
nonisolated struct PromptTally: Equatable, Sendable {
    let prompts: Int
    let replied: Int

    init(_ marks: [ChildMark]?) {
        let prompts = (marks ?? []).filter { !$0.isTask }
        self.prompts = prompts.count
        replied = prompts.filter(\.isDone).count
    }

    var text: String? { line(count: "\(prompts) 条提示词") }

    /// 任务页"提示词"标题旁的写法："3 · 1 已回复"，不再重复"提示词"。
    var heading: String? { line(count: "\(prompts)") }

    /// 条数在前，有回复时接"1 已回复" / "全部已回复"；没有提示词时不写。
    private func line(count: String) -> String? {
        guard prompts > 0 else { return nil }
        guard replied > 0 else { return count }
        return "\(count) · \(replied == prompts ? "全部已回复" : "\(replied) 已回复")"
    }

    func suggestsDone(_ task: Card) -> Bool {
        task.status != .done && prompts > 0 && replied == prompts
    }
}

/// 提示词卡上右边那颗钮做什么（见 `PromptState.action`）；看会话带着要打开的那个会话，卡片不再自己从状态里找。
nonisolated enum PromptAction: Equatable, Sendable {
    case handOff, handAgain
    case watch(PiSessionListItem)
}

/// 一条提示词此刻怎样：没交出去、正在开会话、交给的会话在处理（含话还在路上）、会话没回复就结束了、那一轮做完了
/// （已回复，见 `CueStore.childMarks`）。会话读 `AgentLinks`（在路上的请求优先，其次记在提示词上的会话）。
nonisolated enum PromptState: Equatable, Sendable {
    case unsent
    case launching
    case working(PiSessionListItem)
    /// 会话没回复就结束了：可以重新交给 Agent。
    case ended(PiSessionListItem)
    /// 会话记录读不到时（如已从 Mac 删掉）也算回复过。
    case replied(PiSessionListItem?)

    /// 卡上右边那颗钮：没交出去是交给 Agent；Agent 还在处理这条（话在路上、在干活、在等你确认）时只给看会话——
    /// 这时出"再交一次"像是第一次没发出去；做完、出错、没送到或会话结束了才能再交一次。正在开会话时什么都不给。
    var action: PromptAction? {
        switch self {
        case .unsent: .handOff
        case .launching: nil
        // 已回复只说明这一轮有了回答（`CueStore.childMarks`），会话可能还在接着跑工具或等你确认
        case .working(let item), .replied(let item?): Self.handling(item) ? .watch(item) : .handAgain
        case .ended, .replied(nil): .handAgain
        }
    }

    private static func handling(_ item: PiSessionListItem) -> Bool {
        if item.delivery?.isOpen == true { return true }
        guard let state = item.state.state.known else { return false }
        return state.isWorking || state == .waitingForUser
    }

    init(isReplied: Bool, handoff: PiSessionListItem?, launching: Bool) {
        if isReplied {
            self = .replied(handoff)
        } else if let handoff {
            let ended = handoff.state.state == .known(.ended) && handoff.delivery?.isOpen != true
            self = ended ? .ended(handoff) : .working(handoff)
        } else {
            self = launching ? .launching : .unsent
        }
    }
}
