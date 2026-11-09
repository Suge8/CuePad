#if os(macOS)
import CueStore
import CueText
import Foundation

/// 增量索引的可持久化状态。调用方存起来（Codable），下次传回来就只读新增字节。只存摘要与跨行的轮次状态，不存正文。
/// 解不开（格式随 CuePi 升级变了、读的规则换了版本）的检查点当作没有，从头重读。
public struct PiHistoryCheckpoint: Sendable, Codable, Equatable {
    var rules = ReadRules()
    public internal(set) var offset: UInt64 = 0
    public internal(set) var modified: Date?
    var sidecarModified: Date?
    var fingerprint: UInt64 = 0
    var fingerprintLength = 0
    var sessionID: String?
    var cwd: String?
    var name: String?
    /// `name` 是你起的（Claude Code 的 `custom-title`、dsh 来源是 `user` 的标题）：之后 Agent 自己起的不再盖过它
    var nameIsYours = false
    var lastActivity: Date?
    var firstMessage: String?
    var seq: Int64 = 0
    var round: Round?
    /// 最近一次停下一轮的时刻（会话文件里那条中断标记）：终端里的 Claude Code 被停下时不跑钩子，它的接入凭这个收尾（`AgentRuntime.read`）
    public internal(set) var stoppedAt: Date?
    var reply: Reply?
    var recap = PiRecap()
    /// 先于那句话记下的投送请求 id（按 Agent 给那句话的消息 id）：dsh 的插件在话进收件箱时记，话随后才写进会话（`DshHistory`）
    var deliveries: [String: String] = [:]
    /// 解码时认出这个文件不是会话列表里的会话（如 Codex 子代理自己的会话文件，与主会话同层）：索引器不发出它
    var excluded = false
    /// 你说的一句、还在等它的投送请求 id：Grok 把发它的请求 id 写在它之后的那几行上（`GrokHistory`），等到下一行再照常 `said`
    var held: Held?

    /// 读会话的规则的版本：规则变了、已读过的部分要按新规则重读时（长度截断的回答改记未完成、工具结果里的图、Agent 自己起的会话名）加一，
    /// 旧版本的检查点解不开，各家的会话在窗口内从头重读、对话按新规则改写（`CueStore.applyTranscript` 只改写变了的）。
    struct ReadRules: Codable, Equatable {
        static let current = 3
        let version: Int

        init() { version = Self.current }

        init(from decoder: any Decoder) throws {
            version = try decoder.singleValueContainer().decode(Int.self)
            guard version == Self.current else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "读的规则换了版本"))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(version)
        }
    }

    /// 回填时据此不打开文件——启动时绝大多数会话文件都这样，逐个打开、核对开头与偏移曾占回填的八成。被改写或替换的文件修改时间会变，照常走读时的核对（`isResumable`）。
    /// 另存会话名的文件（`sidecarModified`）也要没动过。
    func isCurrent(size: UInt64, modified: Date, sidecarModified: Date?) -> Bool {
        offset == size && self.modified == modified && self.sidecarModified == sidecarModified
    }

    struct Round: Sendable, Codable, Equatable {
        var startedAt: Date?
        var tools = PiToolLog()
        /// 这一轮里你拒绝过它要用的工具（这一轮因此停下时写"已拒绝"）
        var declined = false
    }

    struct Held: Sendable, Codable, Equatable {
        var text: String
        var stored: String
        var id: String
        var seq: Int64
        var at: Date
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

    /// 进行中这一轮到目前为止的经过（`PiRecap.pendingTools`）由轮次推出、不另存。
    var projectedRecap: PiRecap {
        var projected = recap
        projected.pendingTools = round?.tools.settled
        return projected
    }

    mutating func named(_ title: String?, byYou: Bool) {
        guard let title, !title.isEmpty, byYou || !nameIsYours else { return }
        name = title
        nameIsYours = byYou
    }

    /// 整条是信封的（`PiEnvelope`）是扩展借你的名义投进来的机器消息，按 `machine` 处理。
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

    /// CuePad 送进去的（`deliveryID`，话恰好整条是信封）照样带上请求 id：气泡由它接替。
    mutating func machine(_ text: String, _ entry: PiHistory.Entry, deliveryID: String? = nil, into transcript: inout PiHistory.Transcript) {
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? PiToolLog()) }
        transcript.add(self, entry, role: .machine, text: text, deliveryID: deliveryID)
    }

    mutating func roundStarted(at date: Date) {
        round = Round(startedAt: date)
    }

    mutating func toolStarted(id: String, name: String, arguments: PiToolArguments) {
        var current = round ?? Round(startedAt: nil)
        current.tools.start(id: id, name: name, arguments: arguments, cwd: cwd)
        round = current
    }

    mutating func toolFinished(id: String, failed: Bool, images: [String] = []) {
        round?.tools.finish(id: id, failed: failed, images: images)
    }

    mutating func toolDeclined(id: String) {
        round?.tools.finish(id: id, failed: true)
        round?.declined = true
    }

    mutating func spoke(_ text: String, _ entry: PiHistory.Entry) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var current = round ?? Round(startedAt: nil)
        current.tools.say(text)
        round = current
        reply = Reply(text: text, id: entry.id, seq: entry.seq, at: entry.at)
    }

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

    /// 被停下的那条里说了一半的（`said`）也算回答，它就是最后一段。系统行用这一条的 id；说了一半的那段与它同在一条里，
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

    mutating func compacted(_ entry: PiHistory.Entry, into transcript: inout PiHistory.Transcript) {
        transcript.add(self, entry, role: .system, text: PiNotice.compacted.rawValue)
    }

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
