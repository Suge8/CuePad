import Foundation

/// Pi 会话的工作状态。
public enum PiWorkState: String, Sendable, CaseIterable {
  case thinking, outputting, tool, waitingForUser, settled, error

  /// 正在干活（思考、输出、调用工具）。
  public var isWorking: Bool { self == .thinking || self == .outputting || self == .tool }
}

extension Open<PiWorkState> {
  /// 不认识的状态不算在干活。
  public var isWorking: Bool { known?.isWorking == true }
}

/// 需要推送到手机锁屏的事件。只在"进入等你确认"和"从工作中进入完成"的那一次写入上置位，其余写入为 nil，
/// 服务端订阅据此触发一次通知（同一状态下的重复写入不会再通知）。
public enum PiAlert: String, Sendable, CaseIterable {
  case waitingForUser, settled
}

/// 一个 Pi 会话此刻的状态，Mac 写、手机读；每个会话一条，会话结束即删除。
public struct PiSessionState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  /// 写入它的那台 Mac。
  public var hostID: String
  public var title: String
  public var projectID: UUID?
  public var state: Open<PiWorkState>
  /// 工具名、等待确认的问题、错误信息等。
  public var detail: String?
  /// 这次写入是否要通知手机；见 `PiAlert`。
  public var notify: Open<PiAlert>?
  /// 进入当前状态的时间。
  public var stateSince: Date
  public var createdAt: Date
  public var modifiedAt: Date
}

public enum DeliveryStatus: String, Sendable, CaseIterable {
  case pending, executing, succeeded, failed
}

/// 投送请求的发送方式（唯一定义）：直接发送、steer、followUp、放进输入框。
/// 读到本版本不认识的值（`Open.unknown`）时 Mac 端不执行它。
public enum DeliveryMode: String, Sendable, CaseIterable {
  case send, steer, followUp, paste
}

/// 手机发给 Mac 的投送请求：手机写内容与目标，Mac 执行后写回结果，完成后清理。
public struct DeliveryRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var target: SendTarget
  /// 指定执行的那台 Mac（只有它会领取）。必填。
  public var hostID: String
  public var mode: Open<DeliveryMode>
  public var cardID: UUID?
  public var taskID: UUID?
  public var status: Open<DeliveryStatus>
  /// 失败原因等。
  public var resultDetail: String?
  public var handledBy: String?
  public var createdAt: Date
  public var completedAt: Date?
  public var modifiedAt: Date
  /// 本机（发起请求的设备）第一次看到执行结果的时刻，本机时钟；只在本机，不同步。
  public internal(set) var resultReceivedAt: Date?

  /// 往返时间：创建 → 结果回到本机，两端都是发起设备的时钟。执行方与还没收到结果时为 nil。
  public var roundTrip: Duration? {
    resultReceivedAt.map { .milliseconds(Int64(($0.timeIntervalSince(createdAt) * 1000).rounded())) }
  }
}

public enum DeliveryOutcome: Sendable {
  case succeeded
  case failed(String)
}

extension PiSessionState: Record {
  static let table = Table.piSessionStates
  static let columns = ["id", "sessionID", "hostID", "title", "projectID", "state", "detail", "stateSince", "createdAt", "modifiedAt", "notify"]
  var bindings: [any SQLBindable] { [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: Open(rawValue: row.text(5)), detail: row.textOrNil(6), notify: row.textOrNil(10).map(Open.init(rawValue:)),
      stateSince: row.date(7), createdAt: row.date(8), modifiedAt: row.date(9))
  }
}

extension DeliveryRequest: Record {
  static let table = Table.deliveryRequests
  static let columns = [
    "id", "content", "targetKind", "targetName", "targetRef", "hostID", "mode", "cardID", "taskID", "status",
    "resultDetail", "handledBy", "createdAt", "completedAt", "modifiedAt", "resultReceivedAt",
  ]
  static let syncedColumns = columns.filter { $0 != "resultReceivedAt" }
  var bindings: [any SQLBindable] {
    [id, content, target.kind.rawValue, target.name, target.ref, hostID, mode.rawValue, cardID, taskID, status.rawValue, resultDetail, handledBy, createdAt, completedAt, modifiedAt, resultReceivedAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      target: SendTarget(kind: Open(rawValue: row.text(2)), name: row.text(3), ref: row.textOrNil(4)),
      hostID: row.text(5), mode: Open(rawValue: row.text(6)), cardID: row.uuidOrNil(7), taskID: row.uuidOrNil(8),
      status: Open(rawValue: row.text(9)), resultDetail: row.textOrNil(10), handledBy: row.textOrNil(11),
      createdAt: row.date(12), completedAt: row.dateOrNil(13), modifiedAt: row.date(14), resultReceivedAt: row.dateOrNil(15))
  }
}
