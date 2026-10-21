#if os(macOS)
import CueStore
import CueText
import Foundation

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。只存摘要与跨行的轮次状态，不存正文。
/// 解不开（格式随 CuePi 升级变了）的检查点当作没有，从头重读。
public struct PiHistoryCheckpoint: Sendable, Codable, Equatable {
    /// 已消费到的字节偏移（总在一个换行之后）
    public internal(set) var offset: UInt64 = 0
    /// 读到 `offset` 那次文件的修改时间（列目录或读之前取的）
    public internal(set) var modified: Date?
    var fingerprint: UInt64 = 0
    var fingerprintLength = 0
    var sessionID: String?
    var cwd: String?
    var name: String?
    var lastActivity: Date?
    var firstMessage: String?
    /// 已消费的行数（对话消息的 `seq`）
    var seq: Int64 = 0
    /// 这一轮还没做完：开始时间与已调的工具
    var round: Round?
    /// 最近一次停下一轮的时刻（会话文件里那条中断标记）：终端里的 Claude Code 被停下时不跑钩子，它的接入凭这个收尾（`AgentRuntime.read`）
    public internal(set) var stoppedAt: Date?
    /// 最近你说的那句之后、助手最后说的一段（还没归给那句：等下一句你的话或这一轮结束）
    var reply: Reply?
    var recap = PiRecap()
    /// 解码时认出这个文件不是会话列表里的会话（如 Codex 子代理自己的会话文件，与主会话同层）：索引器不发出它
    var excluded = false

    /// 文件从上次读完就没动过：大小正好读到头、修改时间与那次相同。回填时据此不打开文件——启动时绝大多数会话文件都这样，
    /// 逐个打开、核对开头与偏移曾占回填的八成。被改写或替换的文件修改时间会变，照常走读时的核对（`isResumable`）。
    func isCurrent(size: UInt64, modified: Date) -> Bool { offset == size && self.modified == modified }

    struct Round: Sendable, Codable, Equatable {
        var startedAt: Date?
        var tools = PiToolLog()
        /// 这一轮里你拒绝过它要用的工具（这一轮因此停下时写"已拒绝"）
        var declined = false
    }

    struct Reply: Sendable, Codable, Equatable {
        var text: String
        var id: String
        var seq: Int64
        var at: Date
    }
}

/// 对话里每句你的话，回答是它之后、下一句你的话之前助手说的最后一段：各家的解码把助手说的每一段交给 `spoke`，
/// 下一句你的话（`said`，含一轮在跑时插进来的）或这一轮结束（`answered`）时，最后那段归给前一句。
/// 没有回答就结束的一轮按现有规则：被停下留"已停止"（`interrupted`）。
extension PiHistoryCheckpoint {
    /// 看到会话在跑之后读到的最后一轮的开始（接上时已在跑的一轮，`SessionFacts.startTurn(at:)`）：与收尾的时刻（`PiRecap.answeredAt`）
    /// 出自同一份记录、同一个时钟。还开着的一轮取它开始的那条；已收尾的（看到它在跑之后才答完）取收尾那条——它就是那一轮的回答。
    /// 一轮都没读到为 nil。
    var lastTurnStart: Date? {
        if let round { return round.startedAt }
        return recap.answeredAt
    }

    /// 写到会话记录上的摘要：问答，加上进行中这一轮到目前为止的经过（`PiRecap.pendingTools`，由轮次推出、不另存）。
    var projectedRecap: PiRecap {
        var projected = recap
        projected.pendingTools = round?.tools.settled
        return projected
    }

    /// 你说的一句：第一条有文字的成为标题（`PiSessionName.firstMessage`），开始一轮，进对话、成为进行中的提问（单行，≤`PiRecap.promptLimit`）。
    /// 整条是信封的（`PiEnvelope`）是扩展借你的名义投进来的机器消息，按 `machine` 处理。用斜杠技能说的，提问写你发的样子（`PiSkillCall`）。
    /// 一轮在跑时插进来的你的话：前一句已有的回答先归给前一句，之后的话与工具活动算这一句的。
    mutating func said(_ said: PiHistory.Said, _ entry: PiHistory.Entry, deliveryID: String?, into transcript: inout PiHistory.Transcript) {
        if firstMessage == nil { firstMessage = PiSessionName.firstMessage(said.text) }
        guard PiEnvelope.parse(said.text) == nil else { return machine(said.text, entry, deliveryID: deliveryID, into: &transcript) }
        if reply != nil {
            settleReply(into: &transcript)
            round = Round(startedAt: entry.at)
        }
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? PiToolLog()) }
        transcript.add(self, entry, role: .user, text: said.stored, deliveryID: deliveryID)
        recap.pendingPrompt = PiHistory.clip(PiHistory.collapsed(PiSkillCall.shown(said.text)), PiRecap.promptLimit)
    }

    /// 扩展投进会话的机器消息（FireCode 交回子代理结果、审查结论……）：原样进对话（`machine`），开始一轮（在跑时接着这一轮），
    /// 但不是提问，也不把前面说的那段归成回答。CuePad 送进去的（`deliveryID`，话恰好整条是信封）照样带上请求 id：气泡由它接替。
    mutating func machine(_ text: String, _ entry: PiHistory.Entry, deliveryID: String? = nil, into transcript: inout PiHistory.Transcript) {
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? PiToolLog()) }
        transcript.add(self, entry, role: .machine, text: text, deliveryID: deliveryID)
    }

    /// 这一轮开始（Agent 自己标出开始的，如 Codex 的 `task_started`）：重新计时、清掉工具活动。
    mutating func roundStarted(at date: Date) {
        round = Round(startedAt: date)
    }

    mutating func toolStarted(id: String, name: String, arguments: PiToolArguments) {
        var current = round ?? Round(startedAt: nil)
        current.tools.start(id: id, name: name, arguments: arguments, cwd: cwd)
        round = current
    }

    mutating func toolFinished(id: String, failed: Bool) {
        round?.tools.finish(id: id, failed: failed)
    }

    mutating func toolDeclined(id: String) {
        round?.tools.finish(id: id, failed: true)
        round?.declined = true
    }

    /// 助手说了一段（中途调工具前说的、插话后答的、这一轮最后的回答都是）：空白的不算。每段都按先后记进这一轮的经过，
    /// 最后那段在这一轮做完时成为回答、从经过里拿掉（`PiToolLog.summary`）。
    mutating func spoke(_ text: String, _ entry: PiHistory.Entry) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var current = round ?? Round(startedAt: nil)
        current.tools.say(text)
        round = current
        reply = Reply(text: text, id: entry.id, seq: entry.seq, at: entry.at)
    }

    /// 这一轮做完，`text` 是结束它的那段（可以为空——如只调了工具、出错）：最后说的那段成一条消息，带这一轮的工具活动，
    /// 问与答一起更新——提问是这一轮里你说的话，机器消息触发的轮沿用上一次的提问。什么都没说、也没有提问的（只压缩了上下文）只结束这一轮。
    /// 收尾的时刻记在摘要上（`PiRecap.answeredAt`）：歇下就绪只看它。
    mutating func answered(_ text: String, _ entry: PiHistory.Entry, into transcript: inout PiHistory.Transcript) {
        spoke(text, entry)
        if reply != nil {
            settleReply(into: &transcript)
        } else if let prompt = recap.pendingPrompt {
            recap = PiRecap(lastPrompt: prompt, lastReply: "", pendingPrompt: nil)
        }
        recap.answeredAt = entry.at
        round = nil
    }

    /// 进行中的一轮被停下了（终端里 Esc、CuePad 里"停止这一轮"，或你拒绝了它要用的工具）：已经说出的照样是回答——
    /// 被停下的那条里说了一半的（`said`）也算，它就是最后一段；什么都没说的问答不变、提问不再算进行中。
    /// 对话里在回答下面留一行系统行，因拒绝而停的写"已拒绝"，其余"已停止"。系统行用这一条的 id；说了一半的那段与它同在一条里，
    /// id 后加 `#said`，同序号时说的话排在系统行前（`CueStore.piMessages`）。
    mutating func interrupted(_ entry: PiHistory.Entry, said: String = "", into transcript: inout PiHistory.Transcript) {
        guard let current = round else { return }
        spoke(said, PiHistory.Entry(id: entry.id + "#said", seq: entry.seq, at: entry.at))
        if reply != nil { settleReply(into: &transcript) }
        transcript.add(self, entry, role: .system, text: (current.declined ? PiNotice.declined : .stopped).rawValue)
        round = nil
        recap.pendingPrompt = nil
        recap.answeredAt = entry.at
        stoppedAt = entry.at
    }

    /// 压缩上下文：一行系统行，不动问答。
    mutating func compacted(_ entry: PiHistory.Entry, into transcript: inout PiHistory.Transcript) {
        transcript.add(self, entry, role: .system, text: PiNotice.compacted.rawValue)
    }

    /// 最后说的那段归给前一句：成一条消息（带到此为止的工具活动），问与答一起更新。
    private mutating func settleReply(into transcript: inout PiHistory.Transcript) {
        guard let reply else { return }
        let current = round ?? Round(startedAt: nil)
        transcript.add(
            self, PiHistory.Entry(id: reply.id, seq: reply.seq, at: reply.at), role: .pi, text: reply.text, tools: current.tools.summary(),
            roundStartedAt: current.startedAt)
        recap = PiRecap(
            lastPrompt: recap.pendingPrompt ?? recap.lastPrompt, lastReply: PiHistory.clip(reply.text, PiRecap.replyLimit), pendingPrompt: nil,
            answeredAt: recap.answeredAt)
        self.reply = nil
    }
}
#endif
