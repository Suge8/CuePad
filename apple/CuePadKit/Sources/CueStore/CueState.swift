import CueText
import Foundation

public struct CueState: Equatable, Sendable {
  public var state: Open<WorkState>
  public var hostID: String?
  public var bootID: String?
  public var runtimeUntil: Date?
  public var runtimeState: Open<WorkState> { runtimeUntil == nil ? .unknown("unconfirmed") : state }
  public var detail: String?
  public var step: CueActivity.Touch?
  public var round: UUID?
  public var context: CueContext?
  public var left: [CueLeft]
  public var modifiedAt: Date

  public init(
    state: Open<WorkState>, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil, left: [CueLeft] = [],
    modifiedAt: Date = .now, hostID: String? = nil, bootID: String? = nil, runtimeUntil: Date? = nil
  ) {
    self.hostID = hostID
    self.bootID = bootID
    self.runtimeUntil = runtimeUntil
    self.left = left
    self.state = state
    self.detail = detail
    self.step = step
    self.round = round
    self.context = context
    self.modifiedAt = modifiedAt
  }

  static let recordID = DeterministicID.uuid("cue-state")
}

public struct CueContext: StoredJSON, Equatable, Sendable {
  public var used: Int

  public static let renewAt = 100_000

  public static func tokens(_ count: Int) -> String {
    count >= 1000 ? "\((Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))))k" : "\(count)"
  }

  public init(used: Int) {
    self.used = used
  }
}

public enum CueWake: StoredJSON, Equatable, Sendable {
  case enabled
  case message
  case sessionActivity([CueStir])
  case idle
  case schedule([CueFire])
}

public struct CueFire: Codable, Equatable, Sendable {
  public var line: UUID
  public var due: Date

  public init(line: UUID, due: Date) {
    self.line = line
    self.due = due
  }

  public static func late(_ due: Date, at: Date) -> Bool { at.timeIntervalSince(due) > lateAfter }

  private static let lateAfter: TimeInterval = 10 * 60
}

public struct CueStir: Codable, Equatable, Sendable {
  public var kind: CueChange.Kind
  public var session: String?
  public var task: UUID?

  public init(kind: CueChange.Kind, session: String? = nil, task: UUID? = nil) {
    self.kind = kind
    self.session = session
    self.task = task
  }

  public init(_ change: CueChange) {
    self.init(kind: change.kind, session: change.session?.sessionID, task: (change.leaf ?? change.task)?.id)
  }
}

public struct CueLeft: StoredJSON, Hashable, Sendable {
  public var sessionID: String
  public var since: Date

  public init(sessionID: String, since: Date) {
    self.sessionID = sessionID
    self.since = since
  }

  public func holds(for session: SessionState) -> Bool {
    session.sessionID == sessionID && session.stateSince.stored == since.stored
  }
}

public struct CueDuty: Equatable, Sendable {
  public var name: String
  public var left: [CueLeft]
  public var tiers: [String: CueTier]

  public init(name: String, left: [CueLeft] = [], tiers: [String: CueTier] = [:]) {
    self.name = name
    self.left = left
    self.tiers = tiers
  }

  public func leftToYou(_ session: SessionState) -> Bool { left.contains { $0.holds(for: session) } }

  public func tier(of session: SessionState) -> CueTier { CueTier.of(session, chosen: tiers) }
}

extension CueState: Record, SyncedColumns {
  static let table = Table.cueState
  static let fields: [Field] = [
    .plain("id"), .plain("state"), .encrypted("detail"), .plain("modifiedAt"), .plain("round"), .plain("context"),
    .plain("leftToYou"), .encrypted("step"), .plain("hostID"), .plain("bootID"),
  ]
  var bindings: [any SQLBindable] {
    [Self.recordID, state.rawValue, detail, modifiedAt, round, context?.stored, left.isEmpty ? nil : JSONColumn.encode(left), step.map(JSONColumn.encode), hostID, bootID]
  }
  init(row: Row) {
    self.init(
      state: Open(rawValue: row.text(1)), detail: row.textOrNil(2), step: JSONColumn.decode(CueActivity.Touch.self, from: row.textOrNil(7)),
      round: row.uuidOrNil(4), context: row.textOrNil(5).flatMap(CueContext.init(stored:)),
      left: JSONColumn.decodeList(CueLeft.self, from: row.textOrNil(6)), modifiedAt: row.date(3), hostID: row.textOrNil(8), bootID: row.textOrNil(9))
  }
}
