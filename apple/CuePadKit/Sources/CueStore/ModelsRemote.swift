import Foundation

/// Pi 会话的工作状态。其他版本可能写入未知值：保留为 `.unknown`。
public enum PiWorkState: Hashable, Sendable, RawRepresentable {
  case thinking, outputting, tool, waitingForUser, settled, error
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "thinking": self = .thinking
    case "outputting": self = .outputting
    case "tool": self = .tool
    case "waitingForUser": self = .waitingForUser
    case "settled": self = .settled
    case "error": self = .error
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .thinking: "thinking"
    case .outputting: "outputting"
    case .tool: "tool"
    case .waitingForUser: "waitingForUser"
    case .settled: "settled"
    case .error: "error"
    case .unknown(let raw): raw
    }
  }

  /// 正在干活（思考、输出、调用工具）。
  public var isWorking: Bool { self == .thinking || self == .outputting || self == .tool }
}

/// 需要推送到手机锁屏的事件。只在"进入等你确认"和"从工作中进入完成"的那一次写入上置位，其余写入为 nil，
/// 服务端订阅据此触发一次通知（同一状态下的重复写入不会再通知）。其他版本可能写入未知值：保留为 `.unknown`。
public enum PiAlert: Hashable, Sendable, RawRepresentable {
  case waitingForUser, settled
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "waitingForUser": self = .waitingForUser
    case "settled": self = .settled
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .waitingForUser: "waitingForUser"
    case .settled: "settled"
    case .unknown(let raw): raw
    }
  }
}

/// 一个 Pi 会话此刻的状态，Mac 写、手机读；每个会话一条，会话结束即删除。
public struct PiSessionState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  /// 写入它的那台 Mac。
  public var hostID: String
  public var title: String
  public var projectID: UUID?
  public var state: PiWorkState
  /// 工具名、等待确认的问题、错误信息等。
  public var detail: String?
  /// 这次写入是否要通知手机；见 `PiAlert`。
  public var notify: PiAlert?
  /// 进入当前状态的时间。
  public var stateSince: Date
  public var createdAt: Date
  public var modifiedAt: Date
}

public enum DeliveryStatus: Hashable, Sendable, RawRepresentable {
  case pending, executing, succeeded, failed
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "pending": self = .pending
    case "executing": self = .executing
    case "succeeded": self = .succeeded
    case "failed": self = .failed
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .pending: "pending"
    case .executing: "executing"
    case .succeeded: "succeeded"
    case .failed: "failed"
    case .unknown(let raw): raw
    }
  }
}

/// 投送请求的发送方式（唯一定义）：直接发送、steer、followUp、放进输入框。
/// 其他版本可能写入本版本不认识的值：保留为 `.unknown`（原样写回），Mac 端不执行它。
public enum DeliveryMode: Hashable, Sendable, RawRepresentable {
  case send, steer, followUp, paste
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "send": self = .send
    case "steer": self = .steer
    case "followUp": self = .followUp
    case "paste": self = .paste
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .send: "send"
    case .steer: "steer"
    case .followUp: "followUp"
    case .paste: "paste"
    case .unknown(let raw): raw
    }
  }
}

/// 手机发给 Mac 的投送请求：手机写内容与目标，Mac 执行后写回结果，完成后清理。
public struct DeliveryRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var target: SendTarget
  /// 指定执行的那台 Mac（只有它会领取）。必填。
  public var hostID: String
  public var mode: DeliveryMode
  public var cardID: UUID?
  public var taskID: UUID?
  public var status: DeliveryStatus
  /// 失败原因等。
  public var resultDetail: String?
  public var handledBy: String?
  public var createdAt: Date
  public var completedAt: Date?
  public var modifiedAt: Date
}

public enum DeliveryOutcome: Sendable {
  case succeeded
  case failed(String)
}

package enum ProbeKind: Hashable, Sendable, RawRepresentable {
  case ping, pong
  case unknown(String)

  package init(rawValue: String) {
    switch rawValue {
    case "ping": self = .ping
    case "pong": self = .pong
    default: self = .unknown(rawValue)
    }
  }

  package var rawValue: String {
    switch self {
    case .ping: "ping"
    case .pong: "pong"
    case .unknown(let raw): raw
    }
  }
}

/// 延迟探针记录（诊断用）：发起端写 ping，对端应用后写 pong 并带上它自己时钟下的拉取开始与应用时间。
package struct Probe: Identifiable, Equatable, Sendable {
  package let id: UUID
  package var run: String
  package var seq: Int
  package var kind: ProbeKind
  /// 写这条记录的设备标签。
  package var origin: String
  /// 写入时刻（写入者的时钟）。
  package var sentAt: Date
  /// pong 携带：对端开始拉取 / 应用 ping 的时刻（对端时钟）。
  package var peerFetchStartedAt: Date?
  package var peerAppliedAt: Date?
  package var modifiedAt: Date

  package init(
    id: UUID = UUID(), run: String, seq: Int, kind: ProbeKind, origin: String, sentAt: Date,
    peerFetchStartedAt: Date?, peerAppliedAt: Date?, modifiedAt: Date = Date.stamp
  ) {
    self.id = id
    self.run = run
    self.seq = seq
    self.kind = kind
    self.origin = origin
    self.sentAt = sentAt
    self.peerFetchStartedAt = peerFetchStartedAt
    self.peerAppliedAt = peerAppliedAt
    self.modifiedAt = modifiedAt
  }
}

extension PiSessionState: Record {
  static let table = Table.piSessionStates
  static let columns = ["id", "sessionID", "hostID", "title", "projectID", "state", "detail", "stateSince", "createdAt", "modifiedAt", "notify"]
  var bindings: [any SQLBindable] { [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: PiWorkState(rawValue: row.text(5)), detail: row.textOrNil(6), notify: row.textOrNil(10).map(PiAlert.init(rawValue:)),
      stateSince: row.date(7), createdAt: row.date(8), modifiedAt: row.date(9))
  }
}

extension DeliveryRequest: Record {
  static let table = Table.deliveryRequests
  static let columns = [
    "id", "content", "targetKind", "targetName", "targetRef", "hostID", "mode", "cardID", "taskID", "status",
    "resultDetail", "handledBy", "createdAt", "completedAt", "modifiedAt",
  ]
  var bindings: [any SQLBindable] {
    [id, content, target.kind.rawValue, target.name, target.ref, hostID, mode.rawValue, cardID, taskID, status.rawValue, resultDetail, handledBy, createdAt, completedAt, modifiedAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      target: SendTarget(kind: SendTargetKind(rawValue: row.text(2)), name: row.text(3), ref: row.textOrNil(4)),
      hostID: row.text(5), mode: DeliveryMode(rawValue: row.text(6)), cardID: row.uuidOrNil(7), taskID: row.uuidOrNil(8),
      status: DeliveryStatus(rawValue: row.text(9)), resultDetail: row.textOrNil(10), handledBy: row.textOrNil(11),
      createdAt: row.date(12), completedAt: row.dateOrNil(13), modifiedAt: row.date(14))
  }
}

extension Probe: Record {
  static let table = Table.probes
  static let columns = ["id", "run", "seq", "kind", "origin", "sentAt", "peerFetchStartedAt", "peerAppliedAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, run, seq, kind.rawValue, origin, sentAt, peerFetchStartedAt, peerAppliedAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), run: row.text(1), seq: Int(row.int(2)), kind: ProbeKind(rawValue: row.text(3)), origin: row.text(4),
      sentAt: row.date(5), peerFetchStartedAt: row.dateOrNil(6), peerAppliedAt: row.dateOrNil(7), modifiedAt: row.date(8))
  }
}
