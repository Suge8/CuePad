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

    /// 你的 `UserPromptSubmit` 钩子挡下了这句（CuePad 的钩子已开了这一轮）：Claude Code 不跑这一轮，也不跑 `Stop`。几个钩子并行跑，
    /// 挡下的那一行可能早于 CuePad 收到自己的钩子（2.1.318 实测早 3 毫秒），不能拿这一轮的开始比；这句一定在上一个钩子之后才交上来，
    /// 早于它的是之前那句的。
    func promptEnded(at date: Date) {
        guard facts.running, let after = hookBeforeTurn, after < date else { return }
        settlePending(agent: nil, when: "Stop")
        facts.endTurn()
        show(at: .now)
    }

    /// 你在终端里停掉了全部后台子代理（主会话歇着时按 Ctrl-C，2.1.318）：Claude Code 不开一轮，不跑 `Stop` 也不跑 `SubagentStop`，
    /// 只在会话文件里写一行。那时在跑的子代理记成被停下、出在飞清单；后台命令不受影响，留着。之后才开始的不算（每次读到都会再判一次）。
    func agentsStopped(at date: Date) {
        let stopped = facts.subagents.filter { $0.state.phase == .known(.running) && $0.state.startedAt.map { $0 <= date } == true }.map(\.id)
        guard !stopped.isEmpty else { return }
        for agent in stopped { facts.settleSubagent(agent, .interrupted, summary: nil, at: .now) }
        facts.inFlight.subtract(stopped)
        show(at: .now)
    }
}
#endif
