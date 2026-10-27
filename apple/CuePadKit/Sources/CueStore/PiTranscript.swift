import CueText
import Foundation

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

  /// 这几个会话里你这边最近说的几句的时刻（你打的、CuePad 替你或 Cue 发的、你的作答，不分谁说），每个会话从早到晚、至多 `limit` 句；
  /// 没说过话的会话不在结果里。看板推进中一列的线一次读完（`BoardLine`），不读正文：每个会话先倒着找到第 `limit` 句的时刻，再从那里顺着取，都走 `piMessages_sessionID_at`。
  public func recentSaid(in sessions: [String], limit: Int) throws -> [String: [Date]] {
    guard !sessions.isEmpty, limit > 0 else { return [:] }
    let said = "role IN ('\(PiChatRole.user.rawValue)', '\(PiChatRole.answer.rawValue)')"
    let rows = try db.query(
      """
      SELECT j.value, m.at FROM json_each(?1) j JOIN piMessages m ON m.sessionID = j.value AND m.\(said)
        AND m.at >= COALESCE((SELECT at FROM piMessages WHERE sessionID = j.value AND \(said) ORDER BY at DESC LIMIT 1 OFFSET ?2), 0)
      ORDER BY m.at
      """, [String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self), limit - 1]
    ) { ($0.text(0), $0.date(1)) }
    return Dictionary(grouping: rows, by: \.0).mapValues { $0.suffix(limit).map(\.1) }
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
    // 你发出的话成了对话里的消息就是送到了，没送到的也一样：Agent 晚收下的那句以对话为准。
    // 请求等这条消息上了服务器再收走（`markPushed`），这之前气泡由它接替（`PiChat.outgoing`）
    try db.run(
      """
      UPDATE deliveryRequests SET status = '\(DeliveryStatus.succeeded.rawValue)', failure = NULL, completedAt = COALESCE(completedAt, ?2), modifiedAt = ?2
      WHERE mode = '\(DeliveryMode.send.rawValue)' AND status != '\(DeliveryStatus.succeeded.rawValue)' AND id IN (SELECT value FROM json_each(?1))
      """, [Self.idList(transcript.messages.compactMap(\.deliveryID)), Date.stamp])
    for message in transcript.messages {
      try registerAttachments(in: message.text)
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
        // 先按会话聚合再连会话索引：聚合只读 `piMessages_sessionID_at`，不逐条回表读带长文的行
        let quiet = try db.query(
          """
          SELECT m.sessionID FROM (SELECT sessionID, MAX(at) AS at, MAX(createdAt) AS createdAt FROM piMessages GROUP BY sessionID) m
            LEFT JOIN piSessions s ON s.id = m.sessionID
          WHERE COALESCE(s.lastActivityAt, m.at) < ?1 AND m.createdAt < ?1
          """, [cutoff]) { $0.text(0) }
        var keys = Set<String>()
        if !quiet.isEmpty {
          let sessions = JSONColumn.encode(quiet)
          let said = try db.query(
            "SELECT text FROM piMessages WHERE \(Self.userAttachments) AND sessionID IN (SELECT value FROM json_each(?2))",
            [CueFormat.referencePrefix, sessions]) { $0.text(0) }
          keys.formUnion(said.flatMap(CueFormat.attachmentKeys(in:)))
          try db.run("DELETE FROM piMessages WHERE sessionID IN (SELECT value FROM json_each(?))", [sessions])
        }
        let expired = "createdAt < ? AND sessionID NOT IN (SELECT sessionID FROM piMessages)"
        keys.formUnion(try db.query("SELECT hash, name FROM previews WHERE \(expired)", [cutoff]) { AttachmentKey.make(hash: $0.text(0), name: $0.text(1)) })
        try db.run("DELETE FROM previews WHERE \(expired)", [cutoff])
        return try reclaimAttachments(keys)
      }
    }
  }
}
