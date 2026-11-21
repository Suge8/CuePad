#if os(macOS)
import CueStore
import CueText
import Foundation

public struct HistoryCheckpoint: Sendable, Codable, Equatable {
    var rules = ReadRules()
    public internal(set) var offset: UInt64 = 0
    public internal(set) var modified: Date?
    var sidecarModified: Date?
    var fingerprint: UInt64 = 0
    var fingerprintLength = 0
    var sessionID: String?
    var cwd: String?
    var name: String?
    var nameIsYours = false
    var lastActivity: Date?
    var firstMessage: String?
    var model: ModelKey?
    var thinking: String?
    var seq: Int64 = 0
    var round: Round?
    var reply: Reply?
    var recap = Recap()
    var deliveries: [String: String] = [:]
    /// 解码时认出这个文件不是会话列表里的会话（如 Codex 子代理自己的会话文件，与主会话同层）：索引器不发出它
    var excluded = false
    /// 你说的一句、还在等它的投送请求 id：Grok 把发它的请求 id 写在它之后的那几行上（`GrokHistory`），等到下一行再照常 `said`
    var held: Held?
    var cache = CacheTrack()

    struct CacheTrack: Sendable, Codable, Equatable {
        var lastRead: Int?
        var lastAt: Date?
        var lifetime: TimeInterval?
        var rebuilt = false
        /// 已经记过的那条助手消息：Claude Code 把一条消息按内容块拆成几行写，每行带同一份用量
        var counted: String?
    }

    struct ReadRules: Codable, Equatable {
        static let current = 7
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

    func isCurrent(size: UInt64, modified: Date, sidecarModified: Date?) -> Bool {
        offset == size && self.modified == modified && self.sidecarModified == sidecarModified
    }

    struct Round: Sendable, Codable, Equatable {
        var startedAt: Date?
        var tools = ToolLog()
        var declined = false
        /// 这一轮说完了的那条助手消息的 id（Claude Code：`stop_reason` 不是 `tool_use`，没有文字）：紧接着它写的 `turn_duration` 才收这一轮（`ClaudeHistory`）
        var endedBy: String?
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

extension HistoryCheckpoint {
    var lastTurnStart: Date? {
        if let round { return round.startedAt }
        return recap.answeredAt
    }

    var projectedRecap: Recap {
        var projected = recap
        projected.pendingTools = round?.tools.settled
        return projected
    }

    mutating func named(_ title: String?, byYou: Bool) {
        guard let title, !title.isEmpty, byYou || !nameIsYours else { return }
        name = title
        nameIsYours = byYou
    }

    mutating func said(_ said: History.Said, _ entry: History.Entry, deliveryID: String?, into transcript: inout History.Transcript) {
        if firstMessage == nil { firstMessage = SessionName.firstMessage(said.text) }
        guard MessageEnvelope.parse(said.text) == nil else { return machine(said.text, entry, deliveryID: deliveryID, into: &transcript) }
        if reply != nil {
            settleReply(into: &transcript)
            round = Round(startedAt: entry.at)
        }
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? ToolLog()) }
        transcript.add(self, entry, role: .user, text: said.stored, deliveryID: deliveryID)
        recap.pendingPrompt = History.clip(History.collapsed(SkillCall.shown(said.text)), Recap.promptLimit)
    }

    mutating func machine(_ text: String, _ entry: History.Entry, deliveryID: String? = nil, into transcript: inout History.Transcript) {
        if round?.startedAt == nil { round = Round(startedAt: entry.at, tools: round?.tools ?? ToolLog()) }
        transcript.add(self, entry, role: .machine, text: text, deliveryID: deliveryID)
    }

    mutating func roundStarted(at date: Date) {
        round = Round(startedAt: date)
    }

    mutating func toolStarted(id: String, name: String, arguments: ToolArguments) {
        var current = round ?? Round(startedAt: nil)
        current.tools.start(id: id, name: name, arguments: arguments, cwd: cwd)
        round = current
    }

    mutating func toolFinished(id: String, failed: Bool, images: [String] = []) {
        round?.tools.finish(id: id, failed: failed, images: images)
    }

    /// 一次模型请求的用量（`read` 从缓存读的，`fresh` 原价送的：没缓存的输入加写进缓存的）。`id` 相同的只记一次。
    /// `lifetime` 是 Agent 报的保留时长；没报而 `tiered`（Anthropic 的模型，只有 5 分钟与 1 小时两档）时从这个会话见过的推：
    /// 隔了 5 分钟以上还接得上，就是 1 小时那一档（Pi 的会话文件不写档位）。
    /// 都没有时按 `guess` 估，记成估的：缺省一小时（过了一小时哪家的缓存都多半不在了，不会乱报），知道得更细的给自己的。
    /// 没接上缓存的判定照 whycodes：上一次读过至少 `cacheFloor`、这一次读的不到它的四分之一、原价送的至少 `cacheFloor`；
    /// 比 Claude Code 用量页的口径（少读 5% 且 2000 以上）保守，正常往后追加的不会误报。刚压缩完的那一次是预料中的重建。
    mutating func requested(id: String?, read: Int, fresh: Int, lifetime: TimeInterval?, tiered: Bool = false, guess: TimeInterval = 3_600, at: Date) {
        guard read + fresh > 0, id == nil || id != cache.counted else { return }
        let before = cache.lastRead ?? 0
        let missed = !cache.rebuilt && before >= Self.cacheFloor && read < before / 4 && fresh >= Self.cacheFloor
        let outlivedShort = cache.lastAt.map { at.timeIntervalSince($0) > 360 } == true && before >= Self.cacheFloor && read >= before * 3 / 4
        if let lifetime { cache.lifetime = lifetime } else if tiered, outlivedShort { cache.lifetime = 3_600 }
        cache.counted = id
        cache.lastRead = read
        cache.lastAt = at
        cache.rebuilt = false
        round?.tools.requested(context: read + fresh, recached: missed ? fresh : 0, warmUntil: at + (cache.lifetime ?? guess), estimated: cache.lifetime == nil)
    }

    static let cacheFloor = 2_048

    mutating func toolDeclined(id: String) {
        round?.tools.finish(id: id, failed: true)
        round?.declined = true
    }

    mutating func spoke(_ text: String, _ entry: History.Entry) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var current = round ?? Round(startedAt: nil)
        current.tools.say(text)
        round = current
        reply = Reply(text: text, id: entry.id, seq: entry.seq, at: entry.at)
    }

    mutating func answered(_ text: String, _ entry: History.Entry, into transcript: inout History.Transcript) {
        spoke(text, entry)
        if reply != nil {
            settleReply(into: &transcript)
        } else if let prompt = recap.pendingPrompt {
            recap = Recap(lastPrompt: prompt, lastReply: "", pendingPrompt: nil)
        }
        recap.answeredAt = entry.at
        round = nil
    }

    mutating func interrupted(_ entry: History.Entry, said: String = "", into transcript: inout History.Transcript) {
        guard let current = round else { return }
        spoke(said, History.Entry(id: entry.id + "#said", seq: entry.seq, at: entry.at))
        if reply != nil { settleReply(into: &transcript) }
        transcript.add(self, entry, role: .system, text: (current.declined ? ChatNotice.declined : .stopped).rawValue)
        round = nil
        recap.pendingPrompt = nil
        recap.answeredAt = entry.at
    }

    mutating func compacted(_ entry: History.Entry, into transcript: inout History.Transcript) {
        cache.rebuilt = true
        transcript.add(self, entry, role: .system, text: ChatNotice.compacted.rawValue)
    }

    private mutating func settleReply(into transcript: inout History.Transcript) {
        guard let reply else { return }
        let current = round ?? Round(startedAt: nil)
        transcript.add(
            self, History.Entry(id: reply.id, seq: reply.seq, at: reply.at), role: .pi, text: reply.text, tools: current.tools.summary(),
            roundStartedAt: current.startedAt)
        recap = Recap(
            lastPrompt: recap.pendingPrompt ?? recap.lastPrompt, lastReply: History.clip(reply.text, Recap.replyLimit), pendingPrompt: nil,
            answeredAt: recap.answeredAt)
        self.reply = nil
    }
}
#endif
