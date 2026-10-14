import Foundation

public enum DeliveryStatus: String, Sendable, CaseIterable {
  case pending, executing, succeeded, failed
}

/// 投送请求的发送方式（唯一定义）：直接发送、steer、followUp、放进输入框。
/// 读到本版本不认识的值（`Open.unknown`）时 Mac 端不执行它。
public enum DeliveryMode: String, Sendable, CaseIterable {
  case send, steer, followUp
  /// 回答会话正在等的弹窗；正文是 `PiAnswer`（见 `DeliveryRequest.answer`）
  case answer
  /// 连接测试：执行它的 Mac 收到即按成功写回，不碰 Pi、不写发送记录；往返时间就是手机到 Mac 再回来的延迟
  case ping
  /// 在 Mac 上开一个新会话（后台托管）；正文是 `PiLaunch`
  case start
  /// 请 Mac 从会话文件把这个会话的对话补写进来（7 天前活跃过的会话，手机打开时发）；正文是会话 id，不写发送记录
  case transcript
  /// 换会话的模型与思考强度；正文是 `PiConfig`（见 `DeliveryRequest.config`），不写发送记录
  case config
  /// 结束会话（Pi 进程正常收尾退出，会话记录与会话文件都留着）；正文固定为 `end`，不写发送记录
  case end
  /// 停止会话正在跑的这一轮（相当于在 Pi 里按 Esc：只停指挥官自己这一轮，子代理不动），会话回到等你下一句；
  /// 正文固定为 `stop`，不写发送记录
  case stop
  /// 请 Mac 给项目绑定文件夹（或解除绑定）；正文是 `PiBind`（见 `DeliveryRequest.bind`），不写发送记录
  case bind
  /// 斜杠命令：正文是以 / 开头的整行（命令加参数，可接着带上的卡片文字），由 Pi 派发——内置命令（压缩、命名、换模型……）、扩展命令照常执行，
  /// 提示词模板与 skill 展开成一轮提示词（会话正忙时等它做完再说）。不是"你说的话"：不在对话里挂气泡、不写发送记录（与 config、answer 一样），
  /// 带着卡片时只把卡片关联到会话；结果若在会话文件里（压缩、模板展开出的那条用户消息）对话里自然有
  case command
  /// 请 Mac 刷新订阅额度（手机上的额度视图打开、数据陈旧时）：由 Mac 上在线会话里的扩展查一次（`AccountQuota`），新值随同步回来；
  /// 正文固定为 `quota`，不写发送记录；查不到时照常按失败写回，手机不提示，只显示上次的值与更新时间
  case quota

  /// 发给会话本身、会改变它状态的方式（说话与作答）；会话的显示状态只把这几种算进去。命令与设置（config、end、stop、bind）不在其中：
  /// 它们不是"你说的话"，对话只来自会话文件，进度只在回复框上方短暂显示。
  public static let toSession: Set<DeliveryMode> = [.send, .steer, .followUp, .answer]

  /// 你说的话的几种方式（直接说、马上说、等它做完再说）：没能送达时留着等你重发。
  static let talk: [DeliveryMode] = [.send, .steer, .followUp]

  /// SQL `mode IN (…)` 里的列表。
  static func sqlList(_ modes: some Sequence<DeliveryMode>) -> String {
    modes.map { "'\($0.rawValue)'" }.joined(separator: ", ")
  }
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
  public var status: Open<DeliveryStatus>
  /// 失败原因（存储列）；给人看的读 `failure`。
  public var resultDetail: String?
  public var handledBy: String?
  public var createdAt: Date
  public var completedAt: Date?
  public var modifiedAt: Date
  /// 本机（发起请求的设备）第一次看到执行结果的时刻，本机时钟；只在本机，不同步。
  public internal(set) var resultReceivedAt: Date?

  /// 还没有结果（等待执行或执行中）。
  public var isOpen: Bool { status == .known(.pending) || status == .known(.executing) }

  /// 还没被 Mac 领取（仍是 pending）：撤得回、改得了说法。领取后它已交给 Pi，Pi 的扩展接口收不回进了 Pi 队列的话。
  public var isWithdrawable: Bool { status == .known(.pending) }

  /// 没能送达的原因；成功或还在路上是 nil。本机执行器写回的失败总带原因（`DeliveryOutcome.failed`），只有别的版本写来、
  /// 没带原因的记录（含本版本不认识的状态，它不是送达）落到 `unexplainedFailure`——失败说法只在这里兜底，界面与服务不再各写一句。
  public var failure: String? {
    guard !isOpen, status != .known(.succeeded) else { return nil }
    guard let reason = resultDetail, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.unexplainedFailure }
    return reason
  }

  public static let unexplainedFailure = "Mac 没有说明原因"

  /// 发给一个会话的请求（先发的在前）里此刻要显示的那次结束：还在路上的，或没能结束、之后也没再发过别的；结束成功或没请求过是 nil。
  public static func shownEnd(in requests: [DeliveryRequest]) -> DeliveryRequest? {
    guard let end = requests.last(where: { $0.mode == .known(.end) }) else { return nil }
    return end.isOpen || (end.failure != nil && end.id == requests.last?.id) ? end : nil
  }

  /// 新会话请求的内容；其他方式为 nil。
  public var launch: PiLaunch? { mode == .known(.start) ? PiLaunch(stored: content) : nil }

  /// 绑定文件夹请求的内容；其他方式、读不出的为 nil。
  public var bind: PiBind? { mode == .known(.bind) ? PiBind(stored: content) : nil }

  /// 作答请求的答案；其他方式为 nil。
  public var answer: PiAnswer? { mode == .known(.answer) ? PiAnswer(stored: content) : nil }

  /// 配置请求的内容；其他方式为 nil。
  public var config: PiConfig? { mode == .known(.config) ? PiConfig(stored: content) : nil }

  /// 改名请求：带名字的配置请求。
  public var isRename: Bool { config?.name != nil }

  /// 一个会话的请求（按发出先后，即 `CueStore.deliveryRequests(toSession:)` 的顺序）里最近的一条改名。
  /// 会话行（`PiSessionListItem.rename`）与会话页顶栏都按它显示名字，取法只此一处。
  public static func latestRename(in requests: [DeliveryRequest]) -> DeliveryRequest? { requests.last(where: \.isRename) }

  /// 往返时间：创建 → 结果回到本机，两端都是发起设备的时钟。执行方与还没收到结果时为 nil。
  public var roundTrip: Duration? {
    resultReceivedAt.map { .milliseconds(Int64(($0.timeIntervalSince(createdAt) * 1000).rounded())) }
  }
}

public enum DeliveryOutcome: Sendable {
  case succeeded
  case failed(String)
}

extension DeliveryRequest: Record {
  static let table = Table.deliveryRequests
  static let columns = [
    "id", "content", "targetKind", "targetName", "targetRef", "hostID", "mode", "cardID", "status",
    "resultDetail", "handledBy", "createdAt", "completedAt", "modifiedAt", "resultReceivedAt",
  ]
  static let syncedColumns = columns.filter { $0 != "resultReceivedAt" }
  var bindings: [any SQLBindable] {
    [id, content, target.kind.rawValue, target.name, target.ref, hostID, mode.rawValue, cardID, status.rawValue, resultDetail, handledBy, createdAt, completedAt, modifiedAt, resultReceivedAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      target: SendTarget(kind: Open(rawValue: row.text(2)), name: row.text(3), ref: row.textOrNil(4)),
      hostID: row.text(5), mode: Open(rawValue: row.text(6)), cardID: row.uuidOrNil(7),
      status: Open(rawValue: row.text(8)), resultDetail: row.textOrNil(9), handledBy: row.textOrNil(10),
      createdAt: row.date(11), completedAt: row.dateOrNil(12), modifiedAt: row.date(13), resultReceivedAt: row.dateOrNil(14))
  }
}
