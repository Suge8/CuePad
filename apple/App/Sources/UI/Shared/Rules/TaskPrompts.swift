import CueStore

/// 任务行上的提示词计数："3 条提示词 · 1 已回复"（全部回复了写"全部已回复"）；没有提示词时不写。
/// 全部提示词都已回复、任务还没完成时，行上轻轻问一句要不要标记完成——任务不自动完成，由用户确认。
nonisolated struct PromptTally: Equatable, Sendable {
    let prompts: Int
    let replied: Int

    init(_ marks: [ChildMark]?) {
        let prompts = (marks ?? []).filter { !$0.isTask }
        self.prompts = prompts.count
        replied = prompts.filter(\.isDone).count
    }

    var text: String? {
        guard prompts > 0 else { return nil }
        guard replied > 0 else { return "\(prompts) 条提示词" }
        return "\(prompts) 条提示词 · \(replied == prompts ? "全部" : "\(replied) ")已回复"
    }

    func suggestsDone(_ task: Card) -> Bool {
        task.status != .done && prompts > 0 && replied == prompts
    }
}

/// 一条提示词此刻怎样：没交出去、正在开会话、交给的会话在处理、那一轮做完了（已回复，见 `CueStore.childMarks`）。
/// 会话读 `AgentLinks`（执行过的记在提示词上，手机发出还没执行的读投送请求）。
nonisolated enum PromptState: Equatable, Sendable {
    case unsent
    case launching
    case working(PiSessionListItem)
    /// 会话记录读不到时（如已从 Mac 删掉）也算回复过。
    case replied(PiSessionListItem?)

    init(isReplied: Bool, handoff: PiSessionListItem?, launching: Bool) {
        if isReplied {
            self = .replied(handoff)
        } else if let handoff {
            self = .working(handoff)
        } else {
            self = launching ? .launching : .unsent
        }
    }
}
