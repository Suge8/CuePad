import Foundation

/// Pi 会话的工作状态。
public enum PiWorkState: String, Sendable, CaseIterable {
  case thinking, outputting, tool, waitingForUser, settled, error
  /// 自己这轮已经歇下，还有子代理在跑：仍在处理
  case delegating
  /// 会话已结束（Pi 退出、换了会话）：记录留着给手机看近况，过了 `PiStateRecorder.endedRetention` 删除。
  case ended

  /// 正在干活（思考、输出、调用工具）。
  public var isWorking: Bool {
    switch self {
    case .thinking, .outputting, .tool, .delegating: true
    case .waitingForUser, .settled, .error, .ended: false
    }
  }

  /// Pi 自己正在跑一轮（含弹窗等你确认）：此时发消息只能插话或排队。等子代理不算——指挥官这轮已经歇下，消息直接开始新的一轮。
  public var isTurnRunning: Bool {
    switch self {
    case .thinking, .outputting, .tool, .waitingForUser: true
    case .delegating, .settled, .error, .ended: false
    }
  }
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

/// 会话的近况：手机打开会话时看到的"问了什么、答了什么、在等什么"。来自扩展 v4，旧扩展三项都是 nil。
public struct PiRecap: Sendable, Equatable {
  /// 用户最后一条提问，单行，至多 500 字符。
  public var lastPrompt: String?
  /// 助手最后一轮的最终回答文字（不含思考与工具调用），保留换行，至多 1200 字符。
  public var lastReply: String?
  /// 正在等你回答的弹窗；不在等待时为 nil。
  public var question: PiQuestion?

  public init(lastPrompt: String? = nil, lastReply: String? = nil, question: PiQuestion? = nil) {
    self.lastPrompt = lastPrompt
    self.lastReply = lastReply
    self.question = question
  }
}

/// 会话的计时基准（扩展给出，原样写入）。
public struct PiTimes: Sendable, Equatable {
  /// 进入当前粗状态（工作中、等你确认、出错、空闲、已结束）的时间；细状态（思考、工具、等子代理）之间切换不变。
  public var stateSince: Date
  /// 这段连续处理开始的时间：离开空闲起，到彻底歇下为止，中间等你确认也不断；空闲、出错、已结束时为 nil。
  public var busySince: Date?

  public init(stateSince: Date, busySince: Date?) {
    self.stateSince = stateSince
    self.busySince = busySince
  }
}

public enum PiQuestionKind: String, Sendable, CaseIterable {
  /// 是或否
  case confirm
  /// 从选项里选一个
  case select
  /// 填一段文字
  case text
}

/// 等你回答的弹窗。存在同步记录的 `question` 字段里（加密，JSON）。
public struct PiQuestion: Sendable, Equatable {
  /// 这次弹窗的标识，作答时带上；nil 表示只能在 Pi 里答（多行编辑、自定义界面，或旧版本写的只有文案）。
  public var promptID: String?
  /// 不认识的种类（多行编辑、自定义界面、更新版本的新种类）不能从这里作答。
  public var kind: Open<PiQuestionKind>
  /// 标题与说明，换行分隔，至多 500 字符。
  public var text: String
  /// 选择框的选项原文，作答时按原文回传。
  public var options: [String]

  public init(promptID: String?, kind: Open<PiQuestionKind>, text: String, options: [String] = []) {
    self.promptID = promptID
    self.kind = kind
    self.text = text
    self.options = options
  }

  public init(promptID: String?, kind: PiQuestionKind, text: String, options: [String] = []) {
    self.init(promptID: promptID, kind: .known(kind), text: text, options: options)
  }

  /// 能从 CuePad 作答：有标识，种类认识。
  public var isAnswerable: Bool { promptID != nil && kind.known != nil }

  private struct Stored: Codable {
    var promptID: String?
    var kind: String
    var text: String
    var options: [String]
  }

  var stored: String {
    let data = try! JSONEncoder().encode(Stored(promptID: promptID, kind: kind.rawValue, text: text, options: options))
    return String(decoding: data, as: UTF8.self)
  }

  /// 读不成 JSON 的是旧版本写的一段文字：只有文案、不能作答。同步记录里的 `question` 字段即这种存法（通知扩展据此读出问题）。
  public init(stored: String) {
    guard let decoded = try? JSONDecoder().decode(Stored.self, from: Data(stored.utf8)) else {
      self.init(promptID: nil, kind: .unknown(""), text: stored)
      return
    }
    self.init(promptID: decoded.promptID, kind: Open(rawValue: decoded.kind), text: decoded.text, options: decoded.options)
  }
}

/// 对弹窗的回答。
public enum PiAnswerValue: Sendable, Equatable {
  /// 选择框选中的选项原文
  case option(String)
  /// 确认框的是或否
  case confirmed(Bool)
  /// 输入框填的文字
  case text(String)
}

/// 手机发给 Mac 的作答：哪次弹窗、答什么。存在投送请求（方式 `answer`）的正文里（JSON）。
public struct PiAnswer: Sendable, Equatable {
  public var promptID: String
  public var value: PiAnswerValue

  public init(promptID: String, value: PiAnswerValue) {
    self.promptID = promptID
    self.value = value
  }

  private struct Stored: Codable {
    var promptID: String
    var option: String?
    var confirmed: Bool?
    var text: String?
  }

  var stored: String {
    var form = Stored(promptID: promptID)
    switch value {
    case .option(let option): form.option = option
    case .confirmed(let confirmed): form.confirmed = confirmed
    case .text(let text): form.text = text
    }
    return String(decoding: try! JSONEncoder().encode(form), as: UTF8.self)
  }

  init?(stored: String) {
    guard let form = try? JSONDecoder().decode(Stored.self, from: Data(stored.utf8)) else { return nil }
    if let option = form.option {
      value = .option(option)
    } else if let confirmed = form.confirmed {
      value = .confirmed(confirmed)
    } else if let text = form.text {
      value = .text(text)
    } else {
      return nil
    }
    promptID = form.promptID
  }
}

/// 一个 Pi 会话此刻的状态，Mac 写、手机读；每个会话一条，会话结束后标为 `ended` 保留一段时间。
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
  /// 工作目录的最后一段（文件夹名），不含完整路径；手机据此在没有绑定项目时写出会话"在哪"。旧版本写的记录没有。
  public var folder: String?
  /// 近况，见 `PiRecap`（同名字段）。旧版本写的记录没有。
  public var lastPrompt: String?
  public var lastReply: String?
  public var question: PiQuestion?
  /// 这次写入是否要通知手机；见 `PiAlert`。
  public var notify: Open<PiAlert>?
  /// 计时基准，见 `PiTimes`（同名字段）。界面：工作中"已运行"自 `busySince`，等你确认"已等"自 `stateSince`，其余"多久前"自 `stateSince`。
  public var stateSince: Date
  /// 旧版本写的记录没有。
  public var busySince: Date?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 公开给 Mac 端：把桥上的实时会话、历史索引里的会话也写成这种形状，交给同一个近况界面。
  public init(
    id: UUID, sessionID: String, hostID: String, title: String, projectID: UUID?, state: Open<PiWorkState>, detail: String?,
    folder: String?, lastPrompt: String?, lastReply: String?, question: PiQuestion?, notify: Open<PiAlert>?, stateSince: Date,
    busySince: Date?, createdAt: Date, modifiedAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.hostID = hostID
    self.title = title
    self.projectID = projectID
    self.state = state
    self.detail = detail
    self.folder = folder
    self.lastPrompt = lastPrompt
    self.lastReply = lastReply
    self.question = question
    self.notify = notify
    self.stateSince = stateSince
    self.busySince = busySince
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
  }

  /// 一个 Pi 会话对应的记录 id（每个会话一条，任何设备上算出来都一样）。
  public static func recordID(sessionID: String) -> UUID { DeterministicID.uuid("pi-session/\(sessionID)") }
}

public enum DeliveryStatus: String, Sendable, CaseIterable {
  case pending, executing, succeeded, failed
}

/// 投送请求的发送方式（唯一定义）：直接发送、steer、followUp、放进输入框。
/// 读到本版本不认识的值（`Open.unknown`）时 Mac 端不执行它。
public enum DeliveryMode: String, Sendable, CaseIterable {
  case send, steer, followUp, paste
  /// 回答会话正在等的弹窗；正文是 `PiAnswer`（见 `DeliveryRequest.answer`）
  case answer
  /// 连接测试：执行它的 Mac 收到即按成功写回，不碰 Pi、不写发送记录；往返时间就是手机到 Mac 再回来的延迟
  case ping
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

  /// 还没有结果（等待执行或执行中）。
  public var isOpen: Bool { status == .known(.pending) || status == .known(.executing) }

  /// 作答请求的答案；其他方式为 nil。
  public var answer: PiAnswer? { mode == .known(.answer) ? PiAnswer(stored: content) : nil }

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
  static let columns = [
    "id", "sessionID", "hostID", "title", "projectID", "state", "detail", "stateSince", "createdAt", "modifiedAt", "notify", "folder",
    "lastPrompt", "lastReply", "question", "busySince",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue, folder,
     lastPrompt, lastReply, question?.stored, busySince]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: Open(rawValue: row.text(5)), detail: row.textOrNil(6), folder: row.textOrNil(11),
      lastPrompt: row.textOrNil(12), lastReply: row.textOrNil(13), question: row.textOrNil(14).map(PiQuestion.init(stored:)),
      notify: row.textOrNil(10).map(Open.init(rawValue:)), stateSince: row.date(7), busySince: row.dateOrNil(15), createdAt: row.date(8),
      modifiedAt: row.date(9))
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
