import CueText
import Foundation

public enum ChatRole: String, Sendable, CaseIterable {
  case user
  case pi
  case system
  case machine
  case answer
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  public var seq: Int64
  public var role: Open<ChatRole>
  public var text: String
  public var at: Date
  public var tools: Tools?
  public var roundStartedAt: Date?
  public var question: String?
  public var shownText: ShownText?
  public var deliveryID: UUID?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 单条正文上限（字符）。实测近 7 天 60 个会话的 2172 条回答：中位 399、p99 2649、最长 6195 字符；
  /// 8000 字符全部容下，最多约 24KB（加密后仍远低于 CloudKit 单条记录 1MB），超长的通常是整段代码或日志，Mac 上看全文
  public static let textLimit = 8_000

  public init(
    sessionID: String, entryID: String, seq: Int64, role: ChatRole, text: String, at: Date, tools: Tools? = nil,
    roundStartedAt: Date? = nil, deliveryID: UUID? = nil, question: String? = nil, shownText: ShownText? = nil
  ) {
    id = Self.recordID(sessionID: sessionID, entryID: entryID)
    self.sessionID = sessionID
    self.seq = seq
    self.role = .known(role)
    self.text = role == .machine ? MessageEnvelope.parse(text).map { MessageEnvelope.clipped($0, limit: Self.textLimit) } ?? Self.clipped(text) : Self.clipped(text)
    self.at = at
    self.tools = tools
    self.roundStartedAt = roundStartedAt
    self.deliveryID = deliveryID
    self.question = question
    self.shownText = shownText
    createdAt = .stamp
    modifiedAt = createdAt
  }

  public var notice: ChatNotice? { role == .known(.system) ? ChatNotice(rawValue: text) : nil }

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

  public static func recordID(sessionID: String, entryID: String) -> UUID {
    DeterministicID.uuid("pi-message/\(sessionID)/\(entryID)")
  }
}

extension ChatMessage: Record, SyncedColumns {
  static let table = Table.piMessages
  static let fields: [Field] = [
    .plain("id"), .plain("sessionID"), .plain("seq"), .plain("role"), .encrypted("text"), .plain("at"), .encrypted("tools"),
    .plain("roundStartedAt"), .plain("deliveryID"), .plain("createdAt"), .plain("modifiedAt"), .encrypted("question"),
    .encrypted("shownText"),
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, seq, role.rawValue, text, at, tools?.stored, roundStartedAt, deliveryID, createdAt, modifiedAt, question, shownText?.stored]
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
    shownText = row.textOrNil(12).flatMap(ShownText.init(stored:))
  }

  public var shown: String { shownText?.text ?? text }
}

extension ChatMessage {
  public func saidByCue(_ cueSent: Set<UUID>) -> Bool { role == .known(.user) && deliveryID.map(cueSent.contains) == true }
}

extension ChatMessage {
  public struct Tools: StoredJSON, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
      case edit, command, read, search, other
      case said
      case talk, start, add, done, stop, ask, leave, schedule

      public var acts: Bool {
        switch self {
        case .edit, .talk, .start, .add, .done, .stop, .ask, .leave, .schedule: true
        case .command, .read, .search, .other, .said: false
        }
      }

      public var looks: Bool { self == .read || self == .search || self == .command }
    }

    public struct Item: Codable, Equatable, Sendable {
      public var kind: Kind
      public var target: String
      public var failed: Bool
      public var added: Int?
      public var removed: Int?
      public var task: UUID?
      public var name: String?
      public var session: UUID?
      public var images: [String]?
      public var cueRequests: [UUID]? = nil
      public var deliveries: [UUID]? = nil
      public var calls: [String]? = nil
      public var detail: ToolCallDetail? = nil

      public init(
        kind: Kind, target: String, failed: Bool = false, added: Int? = nil, removed: Int? = nil, task: UUID? = nil, name: String? = nil,
        session: UUID? = nil, images: [String]? = nil
      ) {
        self.kind = kind
        self.target = target
        self.failed = failed
        self.added = added
        self.removed = removed
        self.task = task
        self.name = name
        self.session = session
        self.images = images
      }
    }

    public struct Cache: Codable, Equatable, Sendable {
      public var recached: Int?
      public var context: Int
      public var warmUntil: Date?
      public var estimated: Bool?

      public init(recached: Int? = nil, context: Int, warmUntil: Date? = nil, estimated: Bool? = nil) {
        self.recached = recached
        self.context = context
        self.warmUntil = warmUntil
        self.estimated = estimated
      }
    }

    public var steps: Int
    public var cache: Cache? = nil
    public var items: [Item]

    public var images: [String] {
      var seen = Set<String>()
      return items.flatMap { $0.images ?? [] }.filter { seen.insert($0).inserted }
    }

    static let imagesField = "\"images\""

    static let itemLimit = 30
    public static let targetLimit = 120
    public static let saidLimit = 200

    func keepingDetails(of old: Tools?) -> Tools {
      guard let old else { return self }
      let details = Dictionary(old.items.compactMap { item in item.calls.flatMap { calls in item.detail.map { (calls, $0) } } }, uniquingKeysWith: { first, _ in first })
      var kept = self
      for index in kept.items.indices { kept.items[index].detail = kept.items[index].calls.flatMap { details[$0] } }
      return kept
    }

    public init(steps: Int = 0, items: [Item] = [], cache: Cache? = nil) {
      self.steps = steps
      self.items = items
      self.cache = cache
    }

    public mutating func record(_ item: Item) {
      guard item.kind != .said else { return items.append(item) }
      steps += 1
      if item.kind.acts || item.images != nil || items.count(where: { $0.kind != .said }) < Self.itemLimit { items.append(item) }
    }
  }
}
