#if os(macOS)
import Foundation

/// Claude Code 自己收尾却不跑钩子的几条路：只有会话文件里它写下的那一行（运行时读到就调这里，`ClaudeCodeRuntime.read`），
/// 或登记文件里的 `status`（`registryChanged`）。
extension ClaudeTerminalSession {
    /// 你的 `UserPromptSubmit` 钩子还在查这句时按 Esc：Claude Code 杀掉钩子、把这句放回输入框，会话文件一行不写，不跑 `Stop`，
    /// 只有登记文件的 `status` 从 `busy` 回到 `idle`（2.1.318 实测：按 Esc 后约 90 毫秒）。
    /// 不歇着的 `status` 是 Claude Code 定下它的那一刻（`statusUpdatedAt`，毫秒）晚于这一轮开始才算这一轮的收尾：它在钩子开跑之前写 `busy`
    /// （实测早 4–6 毫秒，写盘慢了 CuePad 会先收到钩子、读到的还是这句之前的 `idle`），这句之前的 `idle` 定在交上这句之前，一定早于 CuePad 收到钩子。
    /// 正常做完的一轮 `Stop` 先到（Claude Code 等 `Stop` 钩子跑完才歇），读到 `idle` 时已不在跑。`shell` 是歇着、在跑 `!` 命令；`waiting` 是在等你（没收尾）。
    func registryChanged() {
        guard facts.running, let start = facts.turnStartedAt, let record = registryRecord,
              let status = record["status"]?.string, ["idle", "shell"].contains(status),
              let stamp = record["statusUpdatedAt"]?.number, Date(timeIntervalSince1970: stamp / 1000) > start else { return }
        settlePending(agent: nil, when: "Stop")
        facts.endTurn()
        show(at: .now)
    }

    /// 这一轮在会话文件里被停下了（中断标记，`PiHistoryCheckpoint.stoppedAt`）：终端里按 Esc（停下在跑的工具、拒绝确认）时
    /// Claude Code 一个钩子都不跑（2.1.299 实测），会话文件与登记文件（`registryChanged`）说明这一轮结束了，哪个先读到算哪个。与 `Stop` 同样收尾；停下之后才开的一轮不算。
    func stopped(at date: Date) {
        guard facts.running, let start = facts.turnStartedAt, start <= date else { return }
        settlePending(agent: nil, when: "Stop")
        facts.endTurn()
        show(at: .now)
    }

    /// 新旧只按记录里的位置分，不拿那一行的时刻与钩子比：CuePad 重启、读规则升级都会从头重读，旧的那一行再来一次
    /// （之前挡下的那句、之后又交上同一句时会被吞掉）；接上之前、已读过的位置之前的都不算。
    func recorded(_ signals: [PiRecordSignal], through offset: UInt64) {
        for signal in signals where signal.end > recordRead {
            switch signal.kind {
            case .promptRefused(let text): refused(text)
            case .agentsStopped: agentsStopped()
            }
        }
        recordRead = max(recordRead, offset)
    }

    nonisolated static func length(of file: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value
    }

    /// 你的 `UserPromptSubmit` 钩子挡下了这句（CuePad 的钩子可能已开了这一轮）：Claude Code 不跑这一轮，也不跑 `Stop`。按原话配对，不比先后：
    /// 几个钩子并行跑，那一行可能早于 CuePad 收到自己的钩子（2.1.318 实测早 3 毫秒），也可能晚于它。CuePad 已收到这句就收掉这一轮，
    /// 还没收到就记下，等紧接着的那个 `UserPromptSubmit`（`handle`）。
    private func refused(_ text: String) {
        guard let prompt = unconfirmedPrompt, Self.refuses(text, prompt) else { return refusedAhead = text }
        unconfirmedPrompt = nil
        guard facts.running else { return }  // 登记文件已回到 `idle`、先收了这一轮（`registryChanged`）
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
    /// 只在会话文件里写一行。那时在跑的子代理记成被停下、出在飞清单；后台命令不受影响，留着。
    private func agentsStopped() {
        let stopped = facts.subagents.filter { $0.state.phase == .known(.running) }.map(\.id)
        guard !stopped.isEmpty else { return }
        for agent in stopped { facts.settleSubagent(agent, .interrupted, summary: nil, at: .now) }
        facts.inFlight.subtract(stopped)
        show(at: .now)
    }
}
#endif
