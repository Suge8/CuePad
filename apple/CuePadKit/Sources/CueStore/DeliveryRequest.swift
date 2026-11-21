import CueText
import Foundation

public enum DeliveryStatus: String, Sendable, CaseIterable {
  case pending, executing
  case preparing
  case confirming
  case unconfirmed
  case succeeded
  case failed = "not_delivered"
}

extension DeliveryStatus {
  static let waiting: Set<DeliveryStatus> = [.pending, .preparing]
  static let waitingSQL = sqlList(waiting.sorted { $0.rawValue < $1.rawValue })
  static let open: Set<DeliveryStatus> = waiting.union([.executing, .confirming])
  static let openSQL = sqlList(open.sorted { $0.rawValue < $1.rawValue })
  static let claimed: Set<DeliveryStatus> = [.executing, .confirming, .unconfirmed]
  static let claimedSQL = sqlList(claimed.sorted { $0.rawValue < $1.rawValue })
  static let ending: Set<DeliveryStatus> = open.union([.unconfirmed])
  static let endingSQL = sqlList(ending.sorted { $0.rawValue < $1.rawValue })
}

public enum DeliveryMode: String, Sendable, CaseIterable {
  case send
  case withdraw
  case answer
  case start
  case transcript
  case step
  case config
  case end
  case stop
  case retry
  case bind
  /// 斜杠命令：正文是以 / 开头的整行，由 Agent 执行；以 Agent 可证实的受理为送达（Pi 执行了扩展命令、压缩做完；OpenCode 的模板经它的命令端点，端点执行完才回，`Slash.speaks`）。
  /// 不是“你说的话”：不在对话里挂气泡，带着卡片时只把卡片关联到会话；结果若在会话文件里（压缩）对话里自然有
  case command
  case quota
  case tidy
  case libraryEdit

  public static let requiresReadySession: Set<DeliveryMode> = [.send, .answer, .command, .config, .retry]

  public static let toSession: Set<DeliveryMode> = [.send, .answer, .retry]

  public var landsAsMessage: Bool {
    switch self {
    case .send, .start: true
    case .withdraw, .answer, .transcript, .step, .config, .end, .stop, .retry, .bind, .command, .quota, .tidy, .libraryEdit: false
    }
  }

  static let landsAsMessageSQL = sqlList(allCases.filter(\.landsAsMessage).sorted { $0.rawValue < $1.rawValue })
}

struct StepRequest: StoredJSON {
  var message: UUID
  var item: Int
}

public enum DeliveryOrigin: String, Sendable, CaseIterable {
  case cue
}

public struct DeliveryRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var target: SendTarget
  public var hostID: String
  public var mode: Open<DeliveryMode>
  public var cardID: UUID?
  public var status: Open<DeliveryStatus>
  public var reason: ShownText?
  public var handledBy: String?
  public var createdAt: Date
  public var completedAt: Date?
  public var deadlineAt: Date? = nil
  public var modifiedAt: Date
  public internal(set) var resultReceivedAt: Date?
  public internal(set) var serverAt: Date? = nil
  public var origin: Open<DeliveryOrigin>?
  public internal(set) var reachedServer = false
  public internal(set) var sessionBindingRevision: SessionBindingRevision?

  public internal(set) var coveredEndRequests: Set<UUID> = []

  public var isFromCue: Bool { origin == .known(.cue) }

  public var isOpen: Bool { status.known.map(DeliveryStatus.open.contains) ?? false }

  public var isWithdrawable: Bool { status.known.map(DeliveryStatus.waiting.contains) == true }

  public var failure: String? {
    guard status == .known(.failed) else { return nil }
    guard let reason = reason?.text, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.unexplainedFailure }
    return reason
  }

  public static let phaseLimit: TimeInterval = 600

  public var dispatchDeadline: Date? { serverAt.map { $0.addingTimeInterval(Self.phaseLimit) } }

  static func dispatchDeadlineSQL(_ alias: String) -> String {
    "(\(alias).serverAt + \(Int(phaseLimit * 1000)))"
  }

  public var expiry: ShownText {
    guard status == .known(.preparing), let waiting = reason, waiting != DeliveryPreparation.ready else { return ShownText("到期仍未派发，没有发出，可以重发") }
    return ShownText("到期仍未派发（\(waiting.embedded)），没有发出，可以重发")
  }

  static let withdrawRefused = ShownText("Mac 已经领取，撤不回")

  public static var interruptedReason: ShownText { ShownText("Mac 上的 CuePad 在执行过程中退出，送达尚未确认，不会自动重发") }

  public static var unexplainedFailure: String { String(localized: "Mac 没有说明原因") }

  public var launch: LaunchRequest? { mode == .known(.start) ? LaunchRequest(stored: content) : nil }

  public var attachmentKeys: [String] { CueFormat.attachmentKeys(in: launch?.prompt ?? content) }

  public var bind: BindRequest? { mode == .known(.bind) ? BindRequest(stored: content) : nil }

  public var tidyOrders: [TidyOrder]? { mode == .known(.tidy) ? JSONColumn.decode([TidyOrder].self, from: content) : nil }

  public var libraryEdit: LibraryEdit? { mode == .known(.libraryEdit) ? LibraryEdit(stored: content) : nil }

  public var answer: Answer? { mode == .known(.answer) ? Answer(stored: content) : nil }

  public var config: SessionConfig? { mode == .known(.config) ? SessionConfig(stored: content) : nil }

  public var isRename: Bool { config?.name != nil }

  public enum EndKind: Equatable, Sendable {
    case explicit
    case task(createdFor: UUID)

    static let explicitContent = "end"

    private struct TaskContent: StoredJSON {
      let createdForTaskID: UUID
    }

    var stored: String {
      switch self {
      case .explicit: Self.explicitContent
      case .task(let owner): TaskContent(createdForTaskID: owner).stored
      }
    }

    init?(stored: String) {
      if stored == Self.explicitContent { self = .explicit; return }
      guard let reason = TaskContent(stored: stored) else { return nil }
      self = .task(createdFor: reason.createdForTaskID)
    }
  }

  public var end: EndKind? { mode == .known(.end) ? EndKind(stored: content) : nil }

  public var isEnding: Bool { mode == .known(.end) && status.known.map(DeliveryStatus.ending.contains) == true }

  static func endingSQL(_ alias: String) -> String {
    "(\(alias).mode = '\(DeliveryMode.end.rawValue)' AND \(alias).status IN (\(DeliveryStatus.endingSQL)))"
  }

  static func explicitEndSQL(_ alias: String) -> String {
    "(\(alias).mode = '\(DeliveryMode.end.rawValue)' AND \(alias).content = '\(EndKind.explicitContent)')"
  }

  public static func latestRename(in requests: [DeliveryRequest]) -> DeliveryRequest? { requests.last(where: \.isRename) }

  public var roundTrip: Duration? {
    resultReceivedAt.map { .milliseconds(Int64(($0.timeIntervalSince(createdAt) * 1000).rounded())) }
  }
}

public enum DeliveryOutcome: Sendable {
  case succeeded
  case confirming(@Sendable (DeliveryRequest) async -> DeliveryOutcome)
  case failed(ShownText)
  case unconfirmed(ShownText)
}

extension DeliveryRequest: Record, SyncedColumns {
  static let table = Table.deliveryRequests
  static let fields: [Field] = [
    .plain("id"), .encrypted("content"), .plain("targetKind"), .encrypted("targetName"), .encrypted("targetRef"), .plain("hostID"),
    .plain("mode"), .plain("cardID"), .plain("status"), .encrypted("failure"), .plain("handledBy"), .plain("createdAt"),
    .plain("completedAt"), .plain("modifiedAt"), .local("resultReceivedAt"), .plain("origin"), .local("serverAt"),
    .plain("deadlineAt"), .plain("sessionBindingRevision"),
  ]
  var bindings: [any SQLBindable] {
    [id, content, target.kind.rawValue, target.name, target.ref, hostID, mode.rawValue, cardID, status.rawValue, reason?.stored, handledBy, createdAt, completedAt, modifiedAt, resultReceivedAt, origin?.rawValue, serverAt, deadlineAt, sessionBindingRevision?.stored]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      target: SendTarget(kind: Open(rawValue: row.text(2)), name: row.text(3), ref: row.textOrNil(4)),
      hostID: row.text(5), mode: Open(rawValue: row.text(6)), cardID: row.uuidOrNil(7),
      status: Open(rawValue: row.text(8)), reason: row.textOrNil(9).flatMap(ShownText.init(stored:)), handledBy: row.textOrNil(10),
      createdAt: row.date(11), completedAt: row.dateOrNil(12), deadlineAt: row.dateOrNil(17), modifiedAt: row.date(13), resultReceivedAt: row.dateOrNil(14), serverAt: row.dateOrNil(16),
      origin: row.textOrNil(15).map(Open.init(rawValue:)), reachedServer: Self.reachedServer(in: row), sessionBindingRevision: row.textOrNil(18).flatMap(SessionBindingRevision.init(stored:)))
  }
}

public struct CueOpenedSession: Equatable, Sendable {
  public let session: String
  public let card: UUID?
  public let at: Date
}
