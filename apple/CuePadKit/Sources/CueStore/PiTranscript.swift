import CueText
import Foundation

/// 对话里一条消息的说话人。
public enum PiChatRole: String, Sendable, CaseIterable {
  /// 你说的（含 CuePad 替你发的）；扩展投进来的机器消息不算，那是 `machine`
  case user
  /// Pi 一轮做完的回答
  case pi
  /// 一行系统记录（`PiNotice`：压缩、这一轮被停下或被你拒绝）；不是谁说的话。设置类条目（换模型、改强度、改名）终端的对话里没有，这里也没有
  case system
  /// 扩展投进会话的机器消息（`PiEnvelope`：FireCode 交回子代理结果、审查结论、观察员的提醒……），正文是信封原文；
  /// 它开始一轮，但不是你说的话（不算提问）
  case machine
  /// 你在 CuePad 里答了会话的提问（`PiAnswer`）：不在会话文件里，由执行作答的那台 Mac 在作答成功时写下（`CueStore.finishDelivery`），
  /// 是"你答了什么"的唯一记录。正文是答案（`PiAnswerValue.label`），`question` 是当时问的；`at` 是答的那一刻，对话按它插进去
  case answer
}

/// 机器消息的一块信封：`<名字>\n正文\n</名字>`。扩展或 Agent 自己投进会话的机器消息（FireCode 的 `<firecode_master_event>`、
/// Codex 子代理的通知……）整条由一块或几块信封组成；块正文止于第一个同名闭合标签，块与块之间夹着真人文字就不是。
/// 四家的读法（轮次）与会话页的卡片都只认这一处。
public struct PiEnvelope: Equatable, Sendable {
  public var name: String
  public var body: String

  public init(name: String, body: String) {
    self.name = name
    self.body = body
  }

  /// 整条是机器消息时的各块，按先后；不是为 nil。
  public static func parse(_ text: String) -> [PiEnvelope]? {
    let source = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
    var blocks: [PiEnvelope] = []
    var location = 0
    while location < source.length {
      guard let match = block.firstMatch(in: source as String, options: .anchored, range: NSRange(location: location, length: source.length - location))
      else { return nil }
      blocks.append(PiEnvelope(name: source.substring(with: match.range(at: 1)), body: source.substring(with: match.range(at: 2))))
      location = NSMaxRange(match.range)
    }
    return blocks.isEmpty ? nil : blocks
  }

  private static let block = try! NSRegularExpression(pattern: #"<([A-Za-z][\w.-]*)>\n((?:(?!\n</\1>)[\s\S])*)\n</\1>\s*"#)

  /// 存进对话时的截断：几块平分上限，各自截正文、信封头尾留着（截在中间会让它认不出是机器消息）。
  static func clipped(_ blocks: [PiEnvelope], limit: Int) -> String {
    let share = limit / blocks.count
    return blocks.map { block in
      "<\(block.name)>\n\(block.body.clipped(share))\n</\(block.name)>"
    }.joined(separator: "\n")
  }
}

/// 你用斜杠技能说的一句（`/skill:名字 参数`）：Pi 把它展开成 `<skill name="名字" location="…">\n…正文…\n</skill>` 再接上参数交给模型，
/// 会话文件里只有展开后的样子。CuePad 写回你发的样子（`line`）：会话页的气泡、会话名与摘要都写它，正文收着、在气泡下点开看。
/// 展开格式随 Pi（1.3 的 `_expandSkillCommand`）；正文开头那行"References are relative to …"是给模型的，不算正文。
/// 被截断的（扩展报的首条消息只有前 `PiSessionName.firstMessageLimit` 个字）认得出名字就行：没有闭合标签时没有参数。
public struct PiSkillCall: Equatable, Sendable {
  public var name: String
  public var arguments: String
  public var body: String

  /// 你发的样子
  public var line: String { arguments.isEmpty ? "/skill:\(name)" : "/skill:\(name) \(arguments)" }

  public static func parse(_ text: String) -> PiSkillCall? {
    guard let head = text.prefixMatch(of: /<skill name="([^"]+)" location="[^"]*">\n/) else { return nil }
    let rest = text[head.range.upperBound...]
    let closing = rest.range(of: "\n</skill>")
    var body = String(rest[..<(closing?.lowerBound ?? rest.endIndex)])
    if let note = body.prefixMatch(of: /References are relative to [^\n]*\n\n?/) { body.removeSubrange(note.range) }
    let arguments = closing.map { rest[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    return PiSkillCall(name: String(head.1), arguments: arguments, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 技能展开的写回你发的样子，其余原样。
  public static func shown(_ text: String) -> String { parse(text)?.line ?? text }
}

/// 对话里的系统行有哪几种，唯一的一处：同步记录里只有说话人与正文，种类由正文认出（正文就是它显示的那句）。
/// 只有压缩换了上下文（对话里画分隔、刻度滑条上一个点）；停下与拒绝只是这一轮怎么结束的（行内一句）。
public enum PiNotice: String, Sendable, CaseIterable {
  case compacted = "已压缩上下文"
  case stopped = "已停止"
  case declined = "已拒绝"

  public var changesContext: Bool { self == .compacted }
}

/// 会话记录上的摘要（列表预览、会话页顶部用）：对话（`PiChatMessage`）的投影，由同一个写者（Mac 读会话文件）
/// 在写对话的同一事务里写（`CueStore.writePiTranscript`），界面直接读、不和对话对账。等你回答的弹窗（`question`）
/// 不在对话里，来自 Pi 桥，由状态记录器写。`lastPrompt` 与 `lastReply` 是最近一轮做完的问答，在这一轮结束时一起更新；
/// 机器消息触发的轮没有新的提问，回答照常更新、提问沿用。
public struct PiRecap: Sendable, Equatable, Codable {
  /// 最近一轮已做完的问答里你说的那句（单行，空白与控制字符折成一个空格，至多 `promptLimit` 字符）。
  public var lastPrompt: String?
  /// 最近一轮已做完的问答里助手的最终回答文字（不含思考与工具调用），保留换行，至多 `replyLimit` 字符。
  public var lastReply: String?
  /// 进行中的提问：你说了、这一轮还没做完（单行，至多 `promptLimit` 字符）；这一轮做完时移进 `lastPrompt`，没有时为 nil。
  /// 界面据此写"你说：… · Pi 正在处理"，上一轮的问答另行折叠，不把新提问和旧回答配在一起。
  public var pendingPrompt: String?
  /// 进行中这一轮到目前为止的经过：做完的工具调用与说过的话（还在跑的调用不算，它在会话状态的 `detail` 里）。会话页末尾实时列出
  /// 这一轮做到哪了；这一轮做完时随回答一起归进那条回答的 `PiChatMessage.tools`，这里清空。没在跑一轮、或还什么都没做时为 nil。
  public var pendingTools: PiChatMessage.Tools?
  /// 最近一轮在会话文件里收尾的时刻（回答、收尾标记或"已停止"那一行的时间戳）：不早于会话记录上这一轮的开始
  /// （`PiSessionState.turnStartedAt`），歇下才算读到了这一轮的回答（`PiSessionState.answered`）。还没有一轮收尾为 nil。
  public var answeredAt: Date?

  public static let promptLimit = 500
  public static let replyLimit = 1_200

  public init(
    lastPrompt: String? = nil, lastReply: String? = nil, pendingPrompt: String? = nil, pendingTools: PiChatMessage.Tools? = nil, answeredAt: Date? = nil
  ) {
    self.lastPrompt = lastPrompt
    self.lastReply = lastReply
    self.pendingPrompt = pendingPrompt
    self.pendingTools = pendingTools
    self.answeredAt = answeredAt
  }
}

/// 会话对话里的一条消息（同步表 `piMessages`，Mac 写、各端只读，只追加；读会话文件的规则变了之后重读，已写过的消息的正文与工具活动会更新）。
///
/// 唯一来源是 Pi 的会话文件：Mac 读会话文件写出（在线会话随文件追加跟上，更早的按需补写），记录 id 由会话 id 与
/// 文件里那一条的 id 算出，重读不重复。一轮一条 Pi 消息：这一轮最后的回答；中途调工具时说的话、思考与工具输出都不同步，
/// 只记这一轮的经过（`tools`：工具调用的分类计数、调用与中途说的话按先后的一份紧凑清单，不含工具输出）和从你说话起做了多久
/// （界面写"跑了 12 步 · 改了 3 个文件 · 2 分钟"）。还在跑的这一轮到目前为止的经过在会话记录上（`PiRecap.pendingTools`）。
public struct PiChatMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Pi 自己的会话 id（同 `PiSessionState.sessionID`）
  public var sessionID: String
  /// 在会话里的先后：会话文件里那一条的序号（文件只追加，重读不变）。对话按它升序排；同一条里出的两行（被停下时说了一半的话与"已停止"）
  /// 序号相同，按说话人排：Agent 说的在系统行前
  public var seq: Int64
  public var role: Open<PiChatRole>
  /// 正文。你的消息是 CuePad 正文格式（`CueFormat`：文字，图片是 `![](cuepad://img/<哈希>)`，与投送请求的 content 同一种），
  /// Pi 的回答与系统行是纯文字。文字至多 `PiChatMessage.textLimit` 个字符，超出截断并以省略号结尾（图片引用不计、不截）
  public var text: String
  /// 这条消息的时间（会话文件里的时间戳）
  public var at: Date
  /// Pi 消息：这一轮的工具活动（没调工具为 nil）；你的消息为 nil
  public var tools: Tools?
  /// Pi 消息：这一轮从哪一刻开始（你说话或机器消息到达）；与 `at` 之差是做了多久。你的消息为 nil
  public var roundStartedAt: Date?
  /// 你的作答（`answer`）：当时问的是什么（问题原文）；别的为 nil
  public var question: String?
  /// 你的消息：它是 CuePad 的哪条投送请求送进去的（扩展把请求 id 写进会话文件里那条消息）；在终端里直接打的为 nil。
  /// 界面据此把那条投送请求的气泡换成这条消息：对话里出现 `deliveryID == request.id` 的消息时不再显示请求气泡
  public var deliveryID: UUID?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 单条正文上限（字符）。实测近 7 天 60 个会话的 2172 条回答：中位 399、p99 2649、最长 6195 字符；
  /// 8000 字符全部容下，最多约 24KB（加密后仍远低于 CloudKit 单条记录 1MB），超长的通常是整段代码或日志，Mac 上看全文
  public static let textLimit = 8_000

  public init(
    sessionID: String, entryID: String, seq: Int64, role: PiChatRole, text: String, at: Date, tools: Tools? = nil,
    roundStartedAt: Date? = nil, deliveryID: UUID? = nil, question: String? = nil
  ) {
    id = Self.recordID(sessionID: sessionID, entryID: entryID)
    self.sessionID = sessionID
    self.seq = seq
    self.role = .known(role)
    self.text = role == .machine ? PiEnvelope.parse(text).map { PiEnvelope.clipped($0, limit: Self.textLimit) } ?? Self.clipped(text) : Self.clipped(text)
    self.at = at
    self.tools = tools
    self.roundStartedAt = roundStartedAt
    self.deliveryID = deliveryID
    self.question = question
    createdAt = .stamp
    modifiedAt = createdAt
  }

  /// 系统行的种类；不是系统行、或别的版本写的不认识的为 nil。
  public var notice: PiNotice? { role == .known(.system) ? PiNotice(rawValue: text) : nil }

  /// 文字超过上限时截断，图片引用原样保留：切坏引用会让图片变成一段乱码。
  private static func clipped(_ text: String) -> String {
    guard text.count > textLimit else { return text }
    let tokens = CueFormat.parse(text)
    let length = tokens.reduce(0) { total, token in
      if case .text(let piece) = token { return total + piece.count }
      return total
    }
    guard length > textLimit else { return text }
    var room = textLimit - 1
    var kept: [CueToken] = []
    for token in tokens {
      guard case .text(let piece) = token else {
        kept.append(token)
        continue
      }
      guard room > 0 else { continue }
      kept.append(.text(String(piece.prefix(room))))
      room -= piece.count
      if room <= 0 { kept.append(.text("…")) }
    }
    return CueFormat.serialize(kept)
  }

  /// 会话文件里一条（你的消息、或一轮最后的回答）对应的记录 id，任何时候重读都一样。
  public static func recordID(sessionID: String, entryID: String) -> UUID {
    DeterministicID.uuid("pi-message/\(sessionID)/\(entryID)")
  }
}

extension PiChatMessage: Record {
  static let table = Table.piMessages
  static let columns = [
    "id", "sessionID", "seq", "role", "text", "at", "tools", "roundStartedAt", "deliveryID", "createdAt", "modifiedAt", "question",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, seq, role.rawValue, text, at, tools?.stored, roundStartedAt, deliveryID, createdAt, modifiedAt, question]
  }
  init(row: Row) {
    id = row.uuid(0)
    sessionID = row.text(1)
    seq = row.int(2)
    role = Open(rawValue: row.text(3))
    text = row.text(4)
    at = row.date(5)
    tools = row.textOrNil(6).flatMap(Tools.init(stored:))
    roundStartedAt = row.dateOrNil(7)
    deliveryID = row.uuidOrNil(8)
    createdAt = row.date(9)
    modifiedAt = row.date(10)
    question = row.textOrNil(11)
  }
}

extension PiChatMessage {
  /// 一轮的经过：调了几次工具（失败的也算，读、改同一个文件只算一次；界面上的"跑了 N 步"）和一份按先后的清单——
  /// 每次调用一条（自己标成败），中途说的每段话也一条（`said`，不是调用）；最后那段话是回答，不在清单里。
  /// Agent 会话的由 Mac 从会话文件汇出，Cue 的由值班的管理器从这一轮的调用汇出（`CueActivity`）；同步记录里存为 JSON（加密字段）。
  public struct Tools: StoredJSON, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
      case edit, command, read, search, other
      /// 中途说的一段话（调工具前后说的"先看看…""测试挂了，查一下"；Cue 用 tell 对你说的）：`target` 是那段话
      case said
      /// Cue 的动作：对会话说话、开工、建任务、收下、停下会话、问你（`target` 写哪件任务与说了什么，`task` 是那件任务）
      case talk, start, add, done, stop, ask

      /// 落了结果的一步（改文件与 Cue 的动作）：清单里总列上，标题行逐类写个数。
      public var acts: Bool {
        switch self {
        case .edit, .talk, .start, .add, .done, .stop, .ask: true
        case .command, .read, .search, .other, .said: false
        }
      }

      /// 只是看了看的一步（读、搜、跑命令）；其余都算动过手（Cue 留给你回、记一笔也是）。
      public var looks: Bool { self == .read || self == .search || self == .command }
    }

    public struct Item: Codable, Equatable, Sendable {
      public var kind: Kind
      /// 文件路径（相对工作目录）、命令的第一个非空行、搜索的模式或工具名；说的话是那段话（至多 `saidLimit` 个字符）
      public var target: String
      public var failed: Bool
      /// 改文件：新增、删除的行数；算不出为 nil
      public var added: Int?
      public var removed: Int?
      /// Cue 动到的任务：清单里点这一条打开它
      public var task: UUID?
      /// Cue 对你说的那条（`CueMessage`）：清单里只留一行，点它跳回对话里的原处
      public var message: UUID?

      public init(
        kind: Kind, target: String, failed: Bool = false, added: Int? = nil, removed: Int? = nil, task: UUID? = nil, message: UUID? = nil
      ) {
        self.kind = kind
        self.target = target
        self.failed = failed
        self.added = added
        self.removed = removed
        self.task = task
        self.message = message
      }
    }

    /// 调用数（与清单的行同一口径；说的话不算）
    public var steps: Int
    /// 清单，按发生先后。落了结果的（`Kind.acts`）与说的话总在里面；其余调用至多列到 `itemLimit` 条，超出的只进计数
    public var items: [Item]

    public static let itemLimit = 30
    /// 清单里一条调用的目标至多这么多字符
    public static let targetLimit = 120
    /// 一段说的话至多这么多字符：够读出它在想什么。进行中这一轮的清单每做完一步就随会话记录整份上传一次，不让长话把它撑大
    public static let saidLimit = 200

    public init(steps: Int = 0, items: [Item] = []) {
      self.steps = steps
      self.items = items
    }

    /// 记下一条：说的话照列、不算一步；做完的一次调用计一步，清单没满或它落了结果（`Kind.acts`）就列上。
    public mutating func record(_ item: Item) {
      guard item.kind != .said else { return items.append(item) }
      steps += 1
      if item.kind.acts || items.count(where: { $0.kind != .said }) < Self.itemLimit { items.append(item) }
    }
  }
}

/// Mac 从一个会话文件读出的一段对话，与会话记录上的摘要一起写（`CueStore.writePiTranscript`）。
public struct PiTranscript: Equatable, Sendable {
  public var sessionID: String
  /// 新读到的消息（已写过的重写也无妨：id 相同、只追加不覆盖）
  public var messages: [PiChatMessage]
  /// 会话记录上的摘要，是对话的投影：最近一轮做完的问与答、进行中的提问（见 `PiRecap`）
  public var recap: PiRecap

  public init(sessionID: String, messages: [PiChatMessage], recap: PiRecap) {
    self.sessionID = sessionID
    self.messages = messages
    self.recap = recap
  }
}

extension CueStore {
  /// 一个会话的完整对话，从早到晚。
  public func piMessages(of sessionID: String) throws -> [PiChatMessage] {
    try select(PiChatMessage.self, where: "sessionID = ?", [sessionID], orderBy: "seq, role, id")
  }

  /// 请 `host` 那台 Mac 把这个会话的对话补写进来（7 天前活跃过、还没同步对话的会话，手机打开时发）。
  /// 已有一条还没被领取的补写请求就是它，不再写第二条：Mac 没回应时它在页面上超时，再打开会话也不会越攒越多；
  /// 那台 Mac 醒来领取一条就够。
  public func requestTranscript(of session: PiSessionState) throws -> DeliveryRequest {
    let waiting = try deliveryRequests(toSession: session.sessionID).last { $0.mode == .known(.transcript) && $0.isWithdrawable }
    if let waiting { return waiting }
    return try requestDelivery(
      session.sessionID, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID,
      mode: .transcript)
  }

  /// 写一段对话，并在同一事务里把摘要写到会话记录上：摘要只有这一个写者，界面不必和对话对账。
  public func writePiTranscript(_ transcript: PiTranscript) throws {
    try write { try applyTranscript(transcript) }
  }

  /// 在调用方的写事务里写对话与摘要（原样写会话文件的投影；"已结束的会话没有进行中的提问"在读出时定，见
  /// `PiSessionState.pendingPrompt`）。会话记录还不存在时只写消息。
  func applyTranscript(_ transcript: PiTranscript) throws {
    // 你发出的话成了对话里的消息，投送请求就到头了：气泡由这条消息接替（`PiChat.outgoing`），请求随之收走，不另等清理。
    // 没送到的也一样：Agent 晚收下的那句以对话为准
    try db.run(
      "DELETE FROM deliveryRequests WHERE mode = '\(DeliveryMode.send.rawValue)' AND id IN (SELECT value FROM json_each(?))",
      [Self.idList(transcript.messages.compactMap(\.deliveryID))])
    for message in transcript.messages {
      try registerImages(in: message.text)
      if try insert(message, ignoringExisting: true) { continue }
      // 已写过的消息只有正文和工具活动会变（读会话文件的规则升级后重读）：同样的内容不改写，免得重复上传
      try db.run(
        "UPDATE piMessages SET text = ?1, tools = ?2, modifiedAt = ?3 WHERE id = ?4 AND (text IS NOT ?1 OR tools IS NOT ?2)",
        [message.text, message.tools?.stored, Date.stamp, message.id])
    }
    let recap = transcript.recap
    try db.run(
      """
      UPDATE piSessionStates SET lastPrompt = ?1, lastReply = ?2, pendingPrompt = ?3, pendingTools = ?4, answeredAt = ?7, modifiedAt = ?5
      WHERE id = ?6 AND (lastPrompt IS NOT ?1 OR lastReply IS NOT ?2 OR pendingPrompt IS NOT ?3 OR pendingTools IS NOT ?4 OR answeredAt IS NOT ?7)
      """,
      [recap.lastPrompt, recap.lastReply, recap.pendingPrompt, recap.pendingTools?.stored, Date.stamp,
       PiSessionState.recordID(sessionID: transcript.sessionID), recap.answeredAt])
  }

  /// 删掉不再需要同步的对话：会话 `window` 内没有活动（按本机会话索引里会话文件的最后活动；索引里没有的按最后一条消息）、
  /// 对话也是 `window` 之前写出的（按需补写的留够 `window`）。在写对话的那台 Mac 上调用。
  /// 对话没了的会话的预览（`window` 之前发的）一起删，文件没有别的预览或图片用着时随之删掉；对话里的图片同样，没有卡片、发送记录、别的对话用着时随之删掉。
  public func prunePiMessages(olderThan window: TimeInterval, now: Date = .now) throws {
    let cutoff = now.addingTimeInterval(-window)
    try reportingFileFailures {
      try write {
        let quiet = """
          SELECT m.sessionID FROM piMessages m LEFT JOIN piSessions s ON s.id = m.sessionID GROUP BY m.sessionID
          HAVING COALESCE(MAX(s.lastActivityAt), MAX(m.at)) < ? AND MAX(m.createdAt) < ?
          """
        let said = try db.query(
          "SELECT text FROM piMessages WHERE \(Self.userImages) AND sessionID IN (\(quiet))",
          [CueFormat.imagePrefix, cutoff, cutoff]) { $0.text(0) }
        var hashes = Set(said.flatMap(CueFormat.imageHashes(in:)))
        try db.run("DELETE FROM piMessages WHERE sessionID IN (\(quiet))", [cutoff, cutoff])
        let expired = "createdAt < ? AND sessionID NOT IN (SELECT sessionID FROM piMessages)"
        hashes.formUnion(try db.query("SELECT hash FROM previews WHERE \(expired)", [cutoff]) { $0.text(0) })
        try db.run("DELETE FROM previews WHERE \(expired)", [cutoff])
        return try reclaimAttachments(hashes)
      }
    }
  }
}
