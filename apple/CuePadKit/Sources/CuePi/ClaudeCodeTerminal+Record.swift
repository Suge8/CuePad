#if os(macOS)
import Foundation

/// Claude Code 自己收尾却不跑钩子的几条路：只有会话文件里它写下的那一行（运行时读到就调这里，`ClaudeCodeRuntime.read`）。
extension ClaudeTerminalSession {
    /// 这一轮在会话文件里被停下了（中断标记，`PiHistoryCheckpoint.stoppedAt`）：终端里按 Esc（停下在跑的工具、拒绝确认）时
    /// Claude Code 一个钩子都不跑（2.1.299 实测），只有会话文件说明这一轮结束了。与 `Stop` 同样收尾；停下之后才开的一轮不算。
    func stopped(at date: Date) {
        guard facts.running, let start = facts.turnStartedAt, start <= date else { return }
        settlePending(agent: nil, when: "Stop")
        facts.endTurn()
        show(at: .now)
    }

    func recorded(_ signal: PiRecordSignal) {
        switch signal {
        case .promptRefused(let text): refused(text)
        case .agentsStopped(let date): agentsStopped(at: date)
        }
    }

    /// 你的 `UserPromptSubmit` 钩子挡下了这句（CuePad 的钩子可能已开了这一轮）：Claude Code 不跑这一轮，也不跑 `Stop`。按原话配对，不比先后：
    /// 几个钩子并行跑，那一行可能早于 CuePad 收到自己的钩子（2.1.318 实测早 3 毫秒），也可能晚于它。CuePad 已收到这句就收掉这一轮，
    /// 还没收到就记下，等紧接着的那个 `UserPromptSubmit`（`handle`）。
    private func refused(_ text: String) {
        guard facts.running, let prompt = unconfirmedPrompt, Self.refuses(text, prompt) else { return refusedAhead = text }
        unconfirmedPrompt = nil
        settlePending(agent: nil, when: "Stop")
        facts.endTurn()
        show(at: .now)
    }

    /// 那一行的原话在正文末尾（2.1.318 源码：`<钩子的话>\n\nOriginal prompt: <这句>`）；钩子要求不显示原话时没有这一段，认作就是这句
    static func refuses(_ text: String, _ prompt: String) -> Bool {
        let marker = "\n\nOriginal prompt: "
        return !text.contains(marker) || text.hasSuffix(marker + prompt)
    }

    /// 你在终端里停掉了全部后台子代理（主会话歇着时按 Ctrl-C，2.1.318）：Claude Code 不开一轮，不跑 `Stop` 也不跑 `SubagentStop`，
    /// 只在会话文件里写一行。那时在跑的子代理记成被停下、出在飞清单；后台命令不受影响，留着。之后才开始的不算（从头重读时旧的那一行会再来）。
    private func agentsStopped(at date: Date) {
        let stopped = facts.subagents.filter { $0.state.phase == .known(.running) && $0.state.startedAt.map { $0 <= date } == true }.map(\.id)
        guard !stopped.isEmpty else { return }
        for agent in stopped { facts.settleSubagent(agent, .interrupted, summary: nil, at: .now) }
        facts.inFlight.subtract(stopped)
        show(at: .now)
    }
}
#endif
