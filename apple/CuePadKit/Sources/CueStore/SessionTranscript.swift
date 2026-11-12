import CueText
import Foundation

/// 会话记录上的摘要（列表预览、会话页顶部用）：对话（`ChatMessage`）的投影，由同一个写者（Mac 读会话文件）
/// 在写对话的同一事务里写（`CueStore.writeTranscript`），界面直接读、不和对话对账。等你回答的弹窗（`question`）
/// 不在对话里，来自 Pi 桥，由状态记录器写。`lastPrompt` 与 `lastReply` 是最近一轮做完的问答，在这一轮结束时一起更新；
/// 机器消息触发的轮没有新的提问，回答照常更新、提问沿用。
public struct Recap: Sendable, Equatable, Codable {
  public var lastPrompt: String?
  public var lastReply: String?
  /// 进行中的提问：你说了、这一轮还没做完（单行，至多 `promptLimit` 字符）；这一轮做完时移进 `lastPrompt`，没有时为 nil。
  /// 界面据此写"你说：… · Pi 正在处理"，上一轮的问答另行折叠，不把新提问和旧回答配在一起。
  public var pendingPrompt: String?
  /// 进行中这一轮到目前为止的经过：做完的工具调用与说过的话（还在跑的调用不算，它在会话状态的 `detail` 里）。会话页末尾实时列出
  /// 这一轮做到哪了；这一轮做完时随回答一起归进那条回答的 `ChatMessage.tools`，这里清空。没在跑一轮、或还什么都没做时为 nil。
  public var pendingTools: ChatMessage.Tools?
  /// 最近一轮在会话文件里收尾的时刻（回答、收尾标记或"已停止"那一行的时间戳）：不早于会话记录上这一轮的开始
  /// （`SessionState.turnStartedAt`），歇下才算读到了这一轮的回答（`SessionState.answered`）。还没有一轮收尾为 nil。
  public var answeredAt: Date?

  public static let promptLimit = 500
  public static let replyLimit = 1_200

  public init(
    lastPrompt: String? = nil, lastReply: String? = nil, pendingPrompt: String? = nil, pendingTools: ChatMessage.Tools? = nil, answeredAt: Date? = nil
  ) {
    self.lastPrompt = lastPrompt
    self.lastReply = lastReply
    self.pendingPrompt = pendingPrompt
    self.pendingTools = pendingTools
    self.answeredAt = answeredAt
  }
}

/// Mac 从一个会话文件读出的一段对话，与会话记录上的摘要一起写（`CueStore.writeTranscript`）。
public struct SessionTranscript: Equatable, Sendable {
  public var sessionID: String
  public var messages: [ChatMessage]
  public var recap: Recap

  public init(sessionID: String, messages: [ChatMessage], recap: Recap) {
    self.sessionID = sessionID
    self.messages = messages
    self.recap = recap
  }
}

extension CueStore {
  public func chatMessages(of sessionID: String) throws -> [ChatMessage] {
    try select(ChatMessage.self, where: "sessionID = ?", [sessionID], orderBy: "seq, role, id")
  }

  /// 这几个会话各自最新那条回答带的提示缓存（会话条等你的卡写它还热多久）；没带的会话不在结果里。走 `piMessages_sessionID_seq`。
  public func latestCaches(in sessions: [String]) throws -> [String: ChatMessage.Tools.Cache] {
    try sessions.reduce(into: [:]) { caches, session in
      let stored = try db.first(
        "SELECT tools FROM piMessages WHERE sessionID = ? AND role = '\(ChatRole.pi.rawValue)' ORDER BY seq DESC LIMIT 1", [session]
      ) { $0.textOrNil(0) }
      caches[session] = (stored ?? nil).flatMap(ChatMessage.Tools.init(stored:))?.cache
    }
  }

  /// 请 `host` 那台 Mac 把这个会话的对话补写进来（7 天前活跃过、还没同步对话的会话，手机打开时发）。
  /// 已有一条还没被领取的补写请求就是它，不再写第二条：Mac 没回应时它在页面上超时，再打开会话也不会越攒越多；
  /// 那台 Mac 醒来领取一条就够。
  public func requestTranscript(of session: SessionState) throws -> DeliveryRequest {
    let waiting = try deliveryRequests(toSession: session.sessionID).last { $0.mode == .known(.transcript) && $0.isWithdrawable }
    if let waiting { return waiting }
    return try requestDelivery(
      session.sessionID, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID,
      mode: .transcript)
  }

  /// 请 `host` 那台 Mac 取那条回答里第 `item` 步的里面（`ToolCallDetail`），写在那一步上同步回来。
  /// 只认做完的一轮：在跑的一轮每多一步都在变，按位置认不住（同一个文件再读一次就并进前面那一步）。
  public func requestStep(_ item: Int, of message: UUID, in session: SessionState) throws -> DeliveryRequest {
    try requestDelivery(
      StepRequest(message: message, item: item).stored, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID),
      on: session.hostID, mode: .step)
  }

  /// 请求（`DeliveryMode.step` 的正文）指的那一步：哪个会话、会话里的哪几次调用。那条回答或那一步已不在为 nil。
  public func stepCalls(_ content: String) throws -> (session: String, calls: [String])? {
    guard let step = StepRequest(stored: content), let message = try find(ChatMessage.self, step.message),
          let items = message.tools?.items, items.indices.contains(step.item), let calls = items[step.item].calls else { return nil }
    return (message.sessionID, calls)
  }

  /// `calls` 是取详情时那一步的几次调用：取的那一下这条回答被重读改写、那个位置已不是这几次调用就抛 `notFound`，不把详情写到别的步上。
  /// 之后再改写时同样几次调用的那一步照旧带着（`Tools.keepingDetails`）。
  public func fillStep(_ content: String, calls: [String], with detail: ToolCallDetail) throws {
    try write {
      guard let step = StepRequest(stored: content), var tools = try find(ChatMessage.self, step.message)?.tools,
            tools.items.indices.contains(step.item), tools.items[step.item].calls == calls else { throw CueStoreError.notFound }
      tools.items[step.item].detail = detail
      try db.run("UPDATE piMessages SET tools = ?1, modifiedAt = ?2 WHERE id = ?3", [tools.stored, Date.stamp, step.message])
    }
  }

  /// 写一段对话，并在同一事务里把摘要写到会话记录上：摘要只有这一个写者，界面不必和对话对账。
  public func writeTranscript(_ transcript: SessionTranscript) throws {
    try write { try applyTranscript(transcript) }
  }

  /// 在调用方的写事务里写对话与摘要（原样写会话文件的投影；"已结束的会话没有进行中的提问"在读出时定，见
  /// `SessionState.pendingPrompt`）。会话记录还不存在时只写消息。
  func applyTranscript(_ transcript: SessionTranscript) throws {
    try applyMessages(transcript.messages, session: transcript.sessionID)
    let recap = transcript.recap
    for key in recap.pendingTools?.images ?? [] { try registerAttachment(key) }
    try db.run(
      """
      UPDATE piSessionStates SET lastPrompt = ?1, lastReply = ?2, pendingPrompt = ?3, pendingTools = ?4, answeredAt = ?7, modifiedAt = ?5
      WHERE id = ?6 AND (lastPrompt IS NOT ?1 OR lastReply IS NOT ?2 OR pendingPrompt IS NOT ?3 OR pendingTools IS NOT ?4 OR answeredAt IS NOT ?7)
      """,
      [recap.lastPrompt, recap.lastReply, recap.pendingPrompt, recap.pendingTools?.stored, Date.stamp,
       SessionState.recordID(sessionID: transcript.sessionID), recap.answeredAt])
  }

  /// 定点核对只补真实用户消息与送达证据，不改正常索引的检查点和轮次摘要。
  public func writeDeliveryReceipts(_ messages: [ChatMessage]) throws {
    let receipts = messages.filter { $0.deliveryID != nil && [.known(.user), .known(.machine)].contains($0.role) }
    try write {
      for (session, messages) in Dictionary(grouping: receipts, by: \.sessionID) {
        try applyMessages(messages, session: session)
      }
    }
  }

  private func applyMessages(_ messages: [ChatMessage], session: String) throws {
    for message in messages {
      try registerAttachments(in: message.text)
      for key in message.tools?.images ?? [] { try registerAttachment(key) }
      if try insert(message, ignoringExisting: true) { continue }
      // 已写过的消息只有正文和工具活动会变（读会话文件的规则升级后重读）：同样的内容不改写，免得重复上传
      let written = try db.first("SELECT tools FROM piMessages WHERE id = ? AND instr(tools, '\"detail\"') > 0", [message.id]) { $0.textOrNil(0) }
      let tools = message.tools?.keepingDetails(of: written?.flatMap(ChatMessage.Tools.init(stored:)))
      try db.run(
        "UPDATE piMessages SET text = ?1, tools = ?2, modifiedAt = ?3 WHERE id = ?4 AND (text IS NOT ?1 OR tools IS NOT ?2)",
        [message.text, tools?.stored, Date.stamp, message.id])
    }
    try reconcileDeliveries(in: messages, session: session)
  }

  /// 真实消息与来源在同一事务收敛；请求原文是发送快照，不拿模型输出冒充投送确认。
  /// 批量按现有主键与 deliveryID 索引查，不逐条读请求；关联只兑现仍有效的请求修订。
  func reconcileDeliveries(in messages: [ChatMessage], session: String) throws {
    let ids = Set(messages.compactMap { message in
      [.known(.user), .known(.machine)].contains(message.role) ? message.deliveryID : nil
    })
    guard !ids.isEmpty else { return }
    let list = Self.idList(ids)
    let requests = try select(
      DeliveryRequest.self,
      where: "id IN (SELECT value FROM json_each(?)) AND mode IN (\(DeliveryMode.landsAsMessageSQL))", [list])
    let recorded = Set(try db.query(
      "SELECT deliveryID FROM sendRecords WHERE deliveryID IN (SELECT value FROM json_each(?))", [list]) { $0.uuid(0) })
    for request in requests where !recorded.contains(request.id) {
      guard request.target.kind == .known(.piSession), request.mode == .known(.start) || request.target.ref == session else { continue }
      let content = request.launch?.prompt ?? request.content
      let target = SendTarget(kind: .piSession, name: request.target.name, ref: session)
      try insertSendRecord(content, to: target, card: request.cardID, delivery: request.id, origin: request.origin)
    }
    try confirmDeliveries(among: ids, session: session)
  }

  /// 删掉不再需要同步的对话：会话 `window` 内没有活动（按本机会话索引里会话文件的最后活动；索引里没有的按最后一条消息）、
  /// 对话也是 `window` 之前写出的（按需补写的留够 `window`）。在写对话的那台 Mac 上调用。
  /// 对话没了的会话的预览（`window` 之前发的）一起删，文件没有别的预览或图片用着时随之删掉；对话里的图片（你的话里的、工具结果里的）同样，
  /// 没有卡片、发送记录、别的对话用着时随之删掉。
  public func pruneMessages(olderThan window: TimeInterval, now: Date = .now) throws {
    let cutoff = now.addingTimeInterval(-window)
    try removingFiles {
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
          let shown = try db.query(
            "SELECT tools FROM piMessages WHERE \(Self.toolImages) AND sessionID IN (SELECT value FROM json_each(?2))",
            [ChatMessage.Tools.imagesField, sessions]) { $0.text(0) }
          keys.formUnion(shown.flatMap { ChatMessage.Tools(stored: $0)?.images ?? [] })
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
