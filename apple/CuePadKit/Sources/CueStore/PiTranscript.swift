import Foundation

/// 对话里一条消息的说话人。
public enum PiChatRole: String, Sendable, CaseIterable {
  /// 你说的（含 CuePad 替你发的）；扩展投进来的机器消息（如 FireCode 交回子代理结果）不算，不进对话
  case user
  /// Pi 一轮做完的回答
  case pi
}

/// 会话对话里的一条消息（同步表 `piMessages`，Mac 写、各端只读，只追加）。
///
/// 唯一来源是 Pi 的会话文件：Mac 读会话文件写出（在线会话随文件追加跟上，更早的按需补写），记录 id 由会话 id 与
/// 文件里那一条的 id 算出，重读不重复。一轮一条 Pi 消息：这一轮最后的回答；中途调工具时说的话、思考与工具输出都不同步，
/// 只记这一轮调了几个工具、从你说话起做了多久（界面写"运行了 5 个工具 · 2 分钟"）。
public struct PiChatMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Pi 自己的会话 id（同 `PiSessionState.sessionID`）
  public var sessionID: String
  /// 在会话里的先后：会话文件里那一条的序号（文件只追加，重读不变）。对话按它升序排
  public var seq: Int64
  public var role: Open<PiChatRole>
  /// 正文，至多 `PiChatMessage.textLimit` 个字符，超出截断并以省略号结尾
  public var text: String
  /// 这条消息的时间（会话文件里的时间戳）
  public var at: Date
  /// Pi 消息：这一轮调了几个工具（0：没调）；你的消息为 0
  public var toolCount: Int
  /// Pi 消息：这一轮从哪一刻开始（你说话或机器消息到达）；与 `at` 之差是做了多久。你的消息为 nil
  public var roundStartedAt: Date?
  /// 你的消息：它是 CuePad 的哪条投送请求送进去的（扩展把请求 id 写进会话文件里那条消息）；在终端里直接打的为 nil。
  /// 界面据此把那条投送请求的气泡换成这条消息：对话里出现 `deliveryID == request.id` 的消息时不再显示请求气泡
  public var deliveryID: UUID?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 单条正文上限（字符）。实测近 7 天 60 个会话的 2172 条回答：中位 399、p99 2649、最长 6195 字符；
  /// 8000 字符全部容下，最多约 24KB（加密后仍远低于 CloudKit 单条记录 1MB），超长的通常是整段代码或日志，Mac 上看全文
  public static let textLimit = 8_000

  public init(
    sessionID: String, entryID: String, seq: Int64, role: PiChatRole, text: String, at: Date, toolCount: Int = 0,
    roundStartedAt: Date? = nil, deliveryID: UUID? = nil
  ) {
    id = Self.recordID(sessionID: sessionID, entryID: entryID)
    self.sessionID = sessionID
    self.seq = seq
    self.role = .known(role)
    self.text = text.count > Self.textLimit ? String(text.prefix(Self.textLimit - 1)) + "…" : text
    self.at = at
    self.toolCount = toolCount
    self.roundStartedAt = roundStartedAt
    self.deliveryID = deliveryID
    createdAt = .stamp
    modifiedAt = createdAt
  }

  /// 会话文件里一条（你的消息、或一轮最后的回答）对应的记录 id，任何时候重读都一样。
  public static func recordID(sessionID: String, entryID: String) -> UUID {
    DeterministicID.uuid("pi-message/\(sessionID)/\(entryID)")
  }
}

extension PiChatMessage: Record {
  static let table = Table.piMessages
  static let columns = [
    "id", "sessionID", "seq", "role", "text", "at", "toolCount", "roundStartedAt", "deliveryID", "createdAt", "modifiedAt",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, seq, role.rawValue, text, at, Int64(toolCount), roundStartedAt, deliveryID, createdAt, modifiedAt]
  }
  init(row: Row) {
    id = row.uuid(0)
    sessionID = row.text(1)
    seq = row.int(2)
    role = Open(rawValue: row.text(3))
    text = row.text(4)
    at = row.date(5)
    toolCount = Int(row.int(6))
    roundStartedAt = row.dateOrNil(7)
    deliveryID = row.uuidOrNil(8)
    createdAt = row.date(9)
    modifiedAt = row.date(10)
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
    try select(PiChatMessage.self, where: "sessionID = ?", [sessionID], orderBy: "seq, id")
  }

  /// 请 `host` 那台 Mac 把这个会话的对话补写进来（7 天前活跃过、还没同步对话的会话，手机打开时发）。
  public func requestTranscript(of session: PiSessionState) throws -> DeliveryRequest {
    try requestDelivery(
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
    for message in transcript.messages { try insert(message, ignoringExisting: true) }
    let recap = transcript.recap
    try db.run(
      """
      UPDATE piSessionStates SET lastPrompt = ?1, lastReply = ?2, pendingPrompt = ?3, modifiedAt = ?4
      WHERE id = ?5 AND (lastPrompt IS NOT ?1 OR lastReply IS NOT ?2 OR pendingPrompt IS NOT ?3)
      """,
      [recap.lastPrompt, recap.lastReply, recap.pendingPrompt, Date.stamp, PiSessionState.recordID(sessionID: transcript.sessionID)])
  }

  /// 删掉不再需要同步的对话：会话 `window` 内没有活动（按本机会话索引里会话文件的最后活动；索引里没有的按最后一条消息）、
  /// 对话也是 `window` 之前写出的（按需补写的留够 `window`）。在写对话的那台 Mac 上调用。
  public func prunePiMessages(olderThan window: TimeInterval, now: Date = .now) throws {
    let cutoff = now.addingTimeInterval(-window)
    try write {
      try db.run(
        """
        DELETE FROM piMessages WHERE sessionID IN (
          SELECT m.sessionID FROM piMessages m LEFT JOIN piSessions s ON s.id = m.sessionID GROUP BY m.sessionID
          HAVING COALESCE(MAX(s.lastActivityAt), MAX(m.at)) < ? AND MAX(m.createdAt) < ?)
        """, [cutoff, cutoff])
    }
  }
}
