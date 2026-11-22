import CueText
import Foundation

public struct Recap: Sendable, Equatable, Codable {
  public var lastPrompt: String?
  public var lastReply: String?
  public var pendingPrompt: String?
  public var pendingTools: ChatMessage.Tools?
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

  public func latestCaches(in sessions: [String]) throws -> [String: ChatMessage.Tools.Cache] {
    try sessions.reduce(into: [:]) { caches, session in
      let stored = try db.first(
        "SELECT tools FROM piMessages WHERE sessionID = ? AND role = '\(ChatRole.pi.rawValue)' ORDER BY seq DESC LIMIT 1", [session]
      ) { $0.textOrNil(0) }
      caches[session] = (stored ?? nil).flatMap(ChatMessage.Tools.init(stored:))?.cache
    }
  }

  public func requestTranscript(of session: SessionState) throws -> DeliveryRequest {
    let waiting = try deliveryRequests(toSession: session.sessionID).last { $0.mode == .known(.transcript) && $0.isWithdrawable }
    if let waiting { return waiting }
    return try requestDelivery(
      session.sessionID, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID,
      mode: .transcript)
  }

  public func requestStep(_ item: Int, of message: UUID, in session: SessionState) throws -> DeliveryRequest {
    try requestDelivery(
      StepRequest(message: message, item: item).stored, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID),
      on: session.hostID, mode: .step)
  }

  public func stepCalls(_ content: String) throws -> (session: String, calls: [String])? {
    guard let step = StepRequest(stored: content), let message = try find(ChatMessage.self, step.message),
          let items = message.tools?.items, items.indices.contains(step.item), let calls = items[step.item].calls else { return nil }
    return (message.sessionID, calls)
  }

  public func fillStep(_ content: String, calls: [String], with detail: ToolCallDetail) throws {
    try write {
      guard let step = StepRequest(stored: content), var tools = try find(ChatMessage.self, step.message)?.tools,
            tools.items.indices.contains(step.item), tools.items[step.item].calls == calls else { throw CueStoreError.notFound }
      tools.items[step.item].detail = detail
      try db.run("UPDATE piMessages SET tools = ?1, modifiedAt = ?2 WHERE id = ?3", [tools.stored, Date.stamp, step.message])
    }
  }

  public func writeTranscript(_ transcript: SessionTranscript) throws {
    try write { try applyTranscript(transcript) }
  }

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
      let written = try db.first("SELECT tools FROM piMessages WHERE id = ? AND instr(tools, '\"detail\"') > 0", [message.id]) { $0.textOrNil(0) }
      let tools = message.tools?.keepingDetails(of: written?.flatMap(ChatMessage.Tools.init(stored:)))
      try db.run(
        "UPDATE piMessages SET text = ?1, tools = ?2, modifiedAt = ?3 WHERE id = ?4 AND (text IS NOT ?1 OR tools IS NOT ?2)",
        [message.text, tools?.stored, Date.stamp, message.id])
    }
    try reconcileDeliveries(in: messages, session: session)
  }

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

  public func pruneMessages(olderThan window: TimeInterval, now: Date = .now) throws {
    let cutoff = now.addingTimeInterval(-window)
    try removingFiles {
      try write {
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
