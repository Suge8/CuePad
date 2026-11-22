import CueText
import Foundation

public enum SessionLaunchIntent: Sendable {
    case new
    case replacing(UUID)
    case repeatingConfirmed
}

extension CueStore {
  @discardableResult
  public func requestDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode = .send, card: UUID? = nil, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write { try insertDelivery(content, to: target, on: host, mode: mode, card: card, cue: cue) }
  }

  public func requestDeliveryWithdrawal(_ id: UUID) throws -> DeliveryRequest? {
    try write {
      guard let original = try find(DeliveryRequest.self, id), original.status == .known(.preparing) else { return nil }
      if let existing = try select(DeliveryRequest.self, where: "mode = 'withdraw' AND content = ? AND status IN (\(DeliveryStatus.openSQL))", [id.uuidString.lowercased()]).first {
        return existing
      }
      return try insertDelivery(id.uuidString.lowercased(), to: original.target, on: original.hostID, mode: .withdraw, cue: false)
    }
  }

  func insertDelivery(
    _ content: String, to target: SendTarget, on host: String, mode: DeliveryMode, card: UUID? = nil, cue: Bool, id: UUID = UUID()
  ) throws -> DeliveryRequest {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankDeliveryContent }
    if let session = target.ref, target.kind == .known(.piSession), DeliveryMode.requiresReadySession.contains(mode) {
      try requireSessionAvailable(session)
    }
    let now = Date.stamp
    var request = DeliveryRequest(
      id: id, content: content, target: target, hostID: host, mode: .known(mode), cardID: card,
      status: .known(.pending), reason: nil, handledBy: nil, createdAt: now, completedAt: nil, modifiedAt: now,
      resultReceivedAt: nil, origin: cue ? .known(.cue) : nil)
    if let card, mode == .start || mode == .send || mode == .command {
      let leaf = try link(of: card)?.isTask == true ? homeLeaf(card) : card
      request.cardID = leaf
      request.sessionBindingRevision = try reviseSessionBinding(leaf, explicit: false)
      try beginTask(leaf, at: now)
    }
    try insert(request)
    for key in Set(request.attachmentKeys) { try registerAttachment(key) }
    if !cue, DeliveryMode.toSession.contains(mode), target.kind == .known(.piSession), let session = target.ref {
      let on = try questionsOn(session)
      _ = try endQuestions(setAsideBy: request.id, where: on.predicate, on.bindings)
    }
    if !cue, DeliveryMode.toSession.contains(mode), target.kind == .known(.piSession), let session = target.ref {
      try reopenTasks(spokenToIn: session)
      try noteRestored(session)
    }
    if let card, mode == .start || DeliveryMode.toSession.contains(mode), let leaf = try leaf(holding: card) {
      try endUnusedSessions(of: leaf, cue: cue)
    }
    return request
  }

  private func leaf(holding card: UUID) throws -> UUID? {
    guard try link(of: card)?.isTask == true else { return nil }
    return try homeLeaf(card)
  }

  public func requestAnswer(_ answer: Answer, to target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try requestDelivery(answer.stored, to: target, on: host, mode: .answer, cue: cue)
  }

  public func requestConfig(_ config: SessionConfig, to target: SendTarget, on host: String) throws -> DeliveryRequest {
    try requestDelivery(config.stored, to: target, on: host, mode: .config)
  }

  public func requestEnd(of target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestControl(.end, of: target, on: host, cue: cue, content: DeliveryRequest.EndKind.explicit.stored) }
  }

  public func requestStop(of target: SendTarget, on host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestControl(.stop, of: target, on: host, cue: cue) }
  }

  public func requestRetry(of target: SendTarget, on host: String) throws -> DeliveryRequest {
    try write { try requestControl(.retry, of: target, on: host, cue: false) }
  }

  func requestControl(_ mode: DeliveryMode, of target: SendTarget, on host: String, cue: Bool, content: String? = nil) throws -> DeliveryRequest {
    let content = content ?? mode.rawValue
    if let ref = target.ref, let open = try deliveryRequests(toSession: ref).last(where: { $0.mode == .known(mode) && $0.content == content && Speech.trip($0, at: .always(at: timing.now())).awaitingResult }) {
      return open
    }
    return try insertDelivery(content, to: target, on: host, mode: mode, cue: cue)
  }

  public func requestLaunch(
    _ launch: LaunchRequest, title: String, on host: String, card: UUID? = nil, cue: Bool = false, intent: SessionLaunchIntent = .new
  ) throws -> DeliveryRequest {
    try write {
      let previous: UUID? = if case .replacing(let id) = intent { id } else { nil }
      switch intent {
      case .repeatingConfirmed: break
      case .new, .replacing:
        let owner = try card ?? previous.flatMap { try deliveryRequest($0)?.cardID }
        if let owner, try unresolvedLaunches(for: owner).contains(where: { $0.id != previous }) {
          throw CueStoreError.deliveryAlreadyHanded
        }
      }
      if let previous, try !removeFailedDelivery(previous), try !removeUnstartedDelivery(previous, locallyOn: nil) {
        throw CueStoreError.deliveryAlreadyHanded
      }
      var launch = launch
      launch.name = try card.flatMap(sessionName(forCard:))
      if let card, try link(of: card)?.isTask == true { launch.createdForTaskID = try homeLeaf(card) }
      return try insertDelivery(
        launch.stored, to: SendTarget(kind: .piSession, name: title, ref: nil), on: host, mode: .start, card: card, cue: cue)
    }
  }

  public func unresolvedLaunches(for card: UUID) throws -> [DeliveryRequest] {
    try select(DeliveryRequest.self, where: "cardID = ? AND \(Self.unresolvedLaunch)", [card], orderBy: "createdAt DESC, rowid DESC")
  }

  public func latestUnresolvedLaunches() throws -> [UUID: DeliveryRequest] {
    let requests = try select(DeliveryRequest.self, where: "cardID IS NOT NULL AND \(Self.unresolvedLaunch)", [], orderBy: "createdAt DESC, rowid DESC")
    return Dictionary(requests.compactMap { request in request.cardID.map { ($0, request) } }, uniquingKeysWith: { newer, _ in newer })
  }

  private static let unresolvedLaunch =
    "mode = '\(DeliveryMode.start.rawValue)' AND status != '\(DeliveryStatus.failed.rawValue)' AND \(launchUnclaimed)"

  func sessionName(forCard card: UUID) throws -> String? {
    guard let card = try find(Card.self, card), card.isTask, !card.heading.isEmpty else { return nil }
    return CueName.clipped(card.heading)
  }

  static let launchUnclaimed = "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.launchToken = \(launchToken("deliveryRequests")))"

  static func launchToken(_ alias: String) -> String {
    "CASE WHEN json_valid(\(alias).content) THEN json_extract(\(alias).content, '$.token') END"
  }

  static func latestHandoff(_ alias: String) -> String {
    "\(alias).createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = \(alias).cardID)"
  }

  func claimLaunchedCards() throws {
    let requests = try select(DeliveryRequest.self, where: """
      mode = 'start' AND EXISTS (
        SELECT 1 FROM piSessionStates s LEFT JOIN cards c ON c.id = deliveryRequests.cardID
        WHERE s.launchToken = \(Self.launchToken("deliveryRequests")) AND (
          (s.createdForTaskID IS NULL AND json_extract(deliveryRequests.content, '$.createdForTaskID') IS NOT NULL)
          OR (json_extract(c.sessionBindingRevision, '$.id') = json_extract(deliveryRequests.sessionBindingRevision, '$.id') AND c.piSessionID IS NOT s.sessionID)))
      """)
    for request in requests {
      guard let launch = request.launch,
        let session = try select(SessionState.self, where: "launchToken = ?", [launch.token]).first else { continue }
      try recordSessionCreationInTransaction(session.sessionID, from: request)
      try linkDeliveredCardInTransaction(request, toSession: session.sessionID)
    }
  }

  public func requestBind(_ bind: BindRequest, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(bind.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .bind)
  }

  public func requestTidy(_ orders: [TidyOrder], on host: String) throws -> DeliveryRequest {
    try requestDelivery(JSONColumn.encode(orders), to: SendTarget(kind: .mac, name: String(localized: "技能与规则"), ref: nil), on: host, mode: .tidy)
  }

  public func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) throws -> DeliveryRequest {
    try requestDelivery(edit.stored, to: SendTarget(kind: .mac, name: title, ref: nil), on: host, mode: .libraryEdit)
  }

  public func deliveryRequests() throws -> [DeliveryRequest] {
    let requests = try select(DeliveryRequest.self, orderBy: "createdAt DESC, rowid DESC")
    let now = timing.now()
    for request in requests {
      if let due = Speech.deadline(request), due > now { expire(at: due) }
    }
    return requests
  }

  public func deliveryRequest(_ id: UUID) throws -> DeliveryRequest? { try find(DeliveryRequest.self, id) }

  public func cueRequests(_ modes: Set<DeliveryMode>) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "origin = '\(DeliveryOrigin.cue.rawValue)' AND mode IN (\(sqlList(modes)))", orderBy: "createdAt, rowid")
  }

  public func cueOpenedSessions() throws -> [CueOpenedSession] {
    try db.query(
      """
      SELECT s.sessionID, r.cardID, s.createdAt FROM deliveryRequests r
        JOIN piSessionStates s ON s.launchToken = \(Self.launchToken("r"))
      WHERE r.origin = '\(DeliveryOrigin.cue.rawValue)' AND r.mode = '\(DeliveryMode.start.rawValue)'
      ORDER BY s.createdAt
      """
    ) { CueOpenedSession(session: $0.text(0), card: $0.uuidOrNil(1), at: $0.date(2)) }
  }

  public nonisolated func outcome(of request: DeliveryRequest) async throws -> DeliveryRequest {
    for try await current in observe({ try $0.latest(of: request) }) {
      guard let current else { throw CueStoreError.notFound }
      if !current.isOpen { return current }
    }
    throw CancellationError()
  }

  public func latest(of request: DeliveryRequest) throws -> DeliveryRequest? {
    if var current = try deliveryRequest(request.id) {
      guard current.isOpen else { return current }
      let moment = Speech.Moment.always(at: timing.now())
      switch Speech.trip(current, at: moment) {
      case .unconfirmed:
        current.status = .known(.unconfirmed)
        current.reason = Speech.unconfirmedReason
      default:
        if let due = Speech.deadline(current) { expire(at: due) }
      }
      return current
    }
    guard try db.first("SELECT 1 FROM piMessages WHERE deliveryID = ?", [request.id], { _ in true }) != nil else { return nil }
    var arrived = request
    arrived.status = .known(.succeeded)
    return arrived
  }

  public func deliveryRequests(toSession sessionID: String) throws -> [DeliveryRequest] {
    try select(
      DeliveryRequest.self, where: "targetKind = '\(SendTargetKind.piSession.rawValue)' AND targetRef = ?", [sessionID],
      orderBy: "createdAt, rowid")
  }

  public func withdrawFailedDelivery(_ id: UUID) throws -> Bool {
    try write { try removeFailedDelivery(id) }
  }

  func removeFailedDelivery(_ id: UUID) throws -> Bool {
    try db.run("DELETE FROM deliveryRequests WHERE id = ? AND status = '\(DeliveryStatus.failed.rawValue)'", [id])
    guard db.changes > 0 else { return false }
    try reopen(where: "setAsideBy = ?", [id])
    return true
  }

  public func deleteDelivery(_ id: UUID) throws {
    try write {
      try db.run("DELETE FROM deliveryRequests WHERE id = ?", [id])
      try reopen(where: "setAsideBy = ?", [id])
    }
  }

  public func withdrawDelivery(_ id: UUID, locallyOn host: String? = nil) throws -> Bool {
    try write { try removeUnstartedDelivery(id, locallyOn: host) }
  }

  func removeUnstartedDelivery(_ id: UUID, locallyOn host: String?) throws -> Bool {
    try db.run(
      """
      DELETE FROM deliveryRequests WHERE id = ?1 AND status IN (\(DeliveryStatus.waitingSQL)) AND handledBy IS NULL
        AND (hostID = ?2 OR NOT EXISTS (
          SELECT 1 FROM syncRecords WHERE recordName = ?1 AND (sentModifiedAt IS NOT NULL OR pushedModifiedAt IS NOT NULL)))
      """, [id, host])
    guard db.changes > 0 else { return false }
    try reopen(where: "setAsideBy = ?", [id])
    return true
  }
}
