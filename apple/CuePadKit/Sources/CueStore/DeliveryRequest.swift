import CueText
import Foundation

public enum DeliveryStatus: String, Sendable, CaseIterable {
  case pending, executing
  /// 可能已交出但无法确认；不再领取，只能由真实消息等正证据收敛。
  case unconfirmed
  case succeeded
  case failed = "not_delivered"
}

extension DeliveryStatus {
  /// 还没有结果的状态（等领取、执行中）：`DeliveryRequest.isOpen` 与 SQL 的 `openSQL` 都从这里来。
  static let open: Set<DeliveryStatus> = [.pending, .executing]
  /// `open` 的 SQL `IN (…)` 列表。
  static let openSQL = sqlList(open.sorted { $0.rawValue < $1.rawValue })
}

/// 投送请求的发送方式（唯一定义）。读到本版本不认识的值（`Open.unknown`）时 Mac 端不执行它。
public enum DeliveryMode: String, Sendable, CaseIterable {
  /// 你说的话（唯一一种）：会话歇着就以它开新一轮；在跑就先打断这一轮，再以它开新一轮（忙不忙以 Mac 执行时的会话为准，
  /// 写请求时看到的状态可能已经过时）。没有排队：投送可能已送达、明确没交出，或交出后仍未确认；未确认不自动重发
  case send
  /// 回答会话正在等的弹窗；正文是 `PiAnswer`（见 `DeliveryRequest.answer`）
  case answer
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
  /// 接着会话出错的那一轮重试（`PiSessionState.canRetry`）：不补发用户消息，也不发"继续"；正文固定为 `retry`，
  /// 不写发送记录。会话在跑或最后一轮不是出错结束的，扩展拒绝（`nothing_to_retry`）
  case retry
  /// 请 Mac 给项目绑定文件夹（或解除绑定）；正文是 `PiBind`（见 `DeliveryRequest.bind`），不写发送记录
  case bind
  /// 斜杠命令：正文是以 / 开头的整行（命令加参数，可接着带上的卡片文字），由 Pi 派发——内置命令（压缩、命名、换模型……）、扩展命令照常执行，
  /// 提示词模板与 skill 展开成一轮提示词（会话在跑时同 `send`，先打断）。不是"你说的话"：不在对话里挂气泡、不写发送记录（与 config、answer 一样），
  /// 带着卡片时只把卡片关联到会话；结果若在会话文件里（压缩、模板展开出的那条用户消息）对话里自然有
  case command
  /// 请 Mac 刷新订阅额度（手机上的额度视图打开、数据陈旧时）：由 Mac 上在线会话里的扩展查一次（`AccountQuota`），新值随同步回来；
  /// 正文固定为 `quota`，不写发送记录；查不到时照常按失败写回，手机不提示，只显示上次的值与更新时间
  case quota
  /// 整理技能与规则（手机上的一键整理、去重、合并）：正文是 `[TidyOrder]`（见 `DeliveryRequest.tidyOrders`），由 Mac 照执行时的文件做，
  /// 那件已不在的不做；不写发送记录
  case tidy
  /// 改一份技能或规则文件（手机上的"发往 Mac"）：正文是 `LibraryEdit`（见 `DeliveryRequest.libraryEdit`），Mac 上的文件已不是基准就退回
  /// "Mac 上刚改过"；不写发送记录
  case libraryEdit

  /// 发给会话本身、会改变它状态的方式（说话、作答与重跑出错的一轮）；会话的显示状态只把这几种算进去。命令与设置（config、end、stop、bind）不在其中：
  /// 它们不是"你说的话"，对话只来自会话文件，进度只在回复框上方短暂显示。
  public static let toSession: Set<DeliveryMode> = [.send, .answer, .retry]
}

/// 请求是谁写的：没有值是你（经 CuePad 的界面或命令行）；Cue 写的标 `cue`。
public enum DeliveryOrigin: String, Sendable, CaseIterable {
  case cue
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
  /// 失败或未确认的原因（各端按自己的语言显示，`ShownText`）；读 `failure` / `Speech.trip`。
  public var failureReason: ShownText?
  public var handledBy: String?
  public var createdAt: Date
  public var completedAt: Date?
  public var modifiedAt: Date
  /// 本机（发起请求的设备）第一次看到执行结果的时刻，本机时钟；只在本机，不同步。
  public internal(set) var resultReceivedAt: Date?
  /// 服务器收下它的时刻（服务器的时钟，拉到它的那台记下）；只在本机，不同步。本机写的、还没拉到过的为 nil。执行它的 Mac 按它算过期（`DeliveryExecutor.maxAge`）。
  public internal(set) var serverAt: Date? = nil
  /// 谁写的（见 `DeliveryOrigin`）；nil 是你。
  public var origin: Open<DeliveryOrigin>?
  /// 服务器收下过这条请求（读的时候由同步元数据推出，不存，`Speech.reachedServerSQL`）：说的话"已发出"的依据。
  public internal(set) var reachedServer = false

  public var isFromCue: Bool { origin == .known(.cue) }

  /// 还没有执行结果（等待执行或执行中）。
  public var isOpen: Bool { status.known.map(DeliveryStatus.open.contains) ?? false }

  /// 尚未领取只是撤回的必要条件；能否撤回还要由库事务核对已发送事实。
  public var isWithdrawable: Bool { status == .known(.pending) && handledBy == nil }

  /// 明确未交出的原因；未知状态不是未送达。缺少原因的明确失败只在这里兜底。
  public var failure: String? {
    guard status == .known(.failed) else { return nil }
    guard let reason = failureReason?.text, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.unexplainedFailure }
    return reason
  }

  static var interruptedReason: ShownText { ShownText("Mac 上的 CuePad 在执行过程中退出，送达尚未确认，不会自动重发") }

  public static var unexplainedFailure: String { String(localized: "Mac 没有说明原因") }

  /// 发给一个会话的请求（先发的在前）里此刻要显示的那次结束到哪了（`Speech`）：还在路上的，或没能结束、之后也没再发过别的；
  /// 结束成功或没请求过是 nil。
  public static func shownEnd(in requests: [DeliveryRequest], at moment: Speech.Moment) -> Speech.Trip? {
    guard let end = requests.last(where: { $0.mode == .known(.end) }) else { return nil }
    switch Speech.trip(end, at: moment) {
    case .sending: return .sending
    case .sent: return .sent
    case .delivered, .unconfirmed: return nil
    case .failed(let failure): return end.id == requests.last?.id ? .failed(failure) : nil
    }
  }

  /// 新会话请求的内容；其他方式为 nil。
  public var launch: PiLaunch? { mode == .known(.start) ? PiLaunch(stored: content) : nil }

  /// 要交出去的话里引用的附件（开工的是开场的话里的）。
  public var attachmentKeys: [String] { CueFormat.attachmentKeys(in: launch?.prompt ?? content) }

  /// 绑定文件夹请求的内容；其他方式、读不出的为 nil。
  public var bind: PiBind? { mode == .known(.bind) ? PiBind(stored: content) : nil }

  /// 整理请求的那几件；其他方式、读不出的为 nil。
  public var tidyOrders: [TidyOrder]? { mode == .known(.tidy) ? JSONColumn.decode([TidyOrder].self, from: content) : nil }

  /// 改文件请求的内容；其他方式、读不出的为 nil。
  public var libraryEdit: LibraryEdit? { mode == .known(.libraryEdit) ? LibraryEdit(stored: content) : nil }

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

/// 执行一次的结果：明确成功、明确未交出，或已交出但无法确认。未知只能由真实消息等正证据收敛，不授权再次派发。
public enum DeliveryOutcome: Sendable {
  case succeeded
  case failed(ShownText)
  case unconfirmed(ShownText)
}

extension DeliveryRequest: Record {
  static let table = Table.deliveryRequests
  static let columns = [
    "id", "content", "targetKind", "targetName", "targetRef", "hostID", "mode", "cardID", "status",
    "failure", "handledBy", "createdAt", "completedAt", "modifiedAt", "resultReceivedAt", "origin", "serverAt",
  ]
  static let syncedColumns = columns.filter { !["resultReceivedAt", "serverAt"].contains($0) }
  var bindings: [any SQLBindable] {
    [id, content, target.kind.rawValue, target.name, target.ref, hostID, mode.rawValue, cardID, status.rawValue, failureReason?.stored, handledBy, createdAt, completedAt, modifiedAt, resultReceivedAt, origin?.rawValue, serverAt]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      target: SendTarget(kind: Open(rawValue: row.text(2)), name: row.text(3), ref: row.textOrNil(4)),
      hostID: row.text(5), mode: Open(rawValue: row.text(6)), cardID: row.uuidOrNil(7),
      status: Open(rawValue: row.text(8)), failureReason: row.textOrNil(9).flatMap(ShownText.init(stored:)), handledBy: row.textOrNil(10),
      createdAt: row.date(11), completedAt: row.dateOrNil(12), modifiedAt: row.date(13), resultReceivedAt: row.dateOrNil(14), serverAt: row.dateOrNil(16),
      origin: row.textOrNil(15).map(Open.init(rawValue:)), reachedServer: row.bool(17))
  }
}

/// Cue 开出的一个新会话（`CueStore.cueOpenedSessions`）：会话 id、开它时带着的卡、会话记录写下的时刻。
public struct CueOpenedSession: Equatable, Sendable {
  public let session: String
  public let card: UUID?
  public let at: Date
}
