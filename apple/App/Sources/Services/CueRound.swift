#if os(macOS)
import CueAgent
import Foundation

/// Cue 的一轮经过（Cue 页的"运行情况"读它）：为什么醒、交给大脑的话、调了哪些工具（参数、结果、耗时）、出没出错、做完时上下文用了多少。
/// 只来自大脑的事件，只在值班这台 Mac 的内存里（`CueKeeper.rounds`）：大脑不落会话，这是唯一看得到经过的地方；不入库、不同步，App 重启就没了。
nonisolated struct CueRound: Identifiable, Sendable {
    let id: Int
    /// 为什么醒；没有醒来就开始的一轮（插进来的话恰好赶上这一轮结束）记作你发来消息
    let wake: CueWake
    let startedAt: Date
    /// 交给大脑的话：第一段是醒来时的信封连同你的话，之后每段是这一轮里插进来的
    var sent: [String]
    var calls: [CueToolCall] = []
    var finishedAt: Date?
    /// 这一轮报的错（原文）；大脑中途退出也记在这里
    var failure: String?
    /// 做完时上下文用了多少 token
    var context: Int?

    /// 记下的结果至多这么多字符：记忆、看板的结果可能很长，留住开头够排查
    static let resultLimit = 20_000

    /// 正在调的那个工具（最后一个还没做完的）
    var running: CueToolCall? { calls.last { $0.finishedAt == nil } }

    mutating func finish(_ id: String, result: String, failed: Bool, at: Date = .now) {
        guard let index = calls.lastIndex(where: { $0.id == id && $0.finishedAt == nil }) else { return }
        calls[index].finishedAt = at
        calls[index].result = result.count <= Self.resultLimit ? result : String(result.prefix(Self.resultLimit)) + "\n…"
        calls[index].failed = failed
    }
}

/// 一轮里的一次工具调用：名字与参数是大脑报的原样（`CueBrainEvent.tool`）。
nonisolated struct CueToolCall: Identifiable, Sendable {
    let id: String
    let name: String
    let arguments: String
    let startedAt: Date
    var finishedAt: Date?
    var result: String?
    var failed = false
}
#endif
