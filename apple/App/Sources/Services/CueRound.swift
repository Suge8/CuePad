#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// Cue 的一轮经过：为什么醒、交给大脑的话、调了哪些工具（参数、结果、耗时）、出没出错、做完时上下文用了多少。
/// 只来自大脑的事件，只在值班这台 Mac 的内存里（`CueKeeper.rounds`）：大脑不落会话，这是唯一的事实源。Mac 的"运行情况"读它的全部；
/// 给人看的那一份由它推出（`process`），写在对话里这一轮开始的位置那一行上（`row`），随库同步到各端。
struct CueRound: Identifiable {
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
    /// 这一轮的经过在对话里的那一行（`CueStore.recordCueRound`）：Cue 自己醒来的一轮醒来就有，你发起的还没调过工具时没有
    var row: UUID?

    /// 记下的结果至多这么多字符：记忆、看板的结果可能很长，留住开头够排查
    static let resultLimit = 20_000

    var running: CueToolCall? { calls.last { $0.finishedAt == nil } }

    /// 这一轮动过手：有一次做完的调用不只是看看（`Kind.looks`）。Cue 自己醒来的一轮动过手才写下最后的话（`CueKeeper`）。
    var acted: Bool { calls.contains { $0.item.map { !$0.kind.looks } ?? false } }

    /// 给人看的经过：做完的调用按先后（还在跑的不算，它是此刻在做的）；一个都没做完为 nil。
    var process: PiChatMessage.Tools? {
        let items = calls.compactMap(\.item)
        guard !items.isEmpty else { return nil }
        var tools = PiChatMessage.Tools()
        for item in items { tools.record(item) }
        return tools
    }

    mutating func finish(_ id: String, result: String, failed: Bool, item: PiChatMessage.Tools.Item) {
        guard let index = calls.lastIndex(where: { $0.id == id && $0.finishedAt == nil }) else { return }
        calls[index].finishedAt = .now
        calls[index].result = result.count <= Self.resultLimit ? result : String(result.prefix(Self.resultLimit)) + "\n…"
        calls[index].failed = failed
        calls[index].item = item
    }
}

/// 一轮里的一次工具调用：名字与参数是大脑报的原样（`CueBrainEvent.tool`）。
struct CueToolCall: Identifiable {
    let id: String
    let name: String
    let arguments: String
    /// 正在用时那一句（`CueActivity.detail`，开始时就查好名字：此刻的状态同步读它，不再等库）
    let detail: String
    let startedAt: Date
    var finishedAt: Date?
    var result: String?
    var failed = false
    /// 做完后在经过清单里的那一条（`CueActivity.item`）
    var item: PiChatMessage.Tools.Item?
}
#endif
