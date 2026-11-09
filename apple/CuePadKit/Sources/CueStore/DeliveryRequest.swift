import CueText
import Foundation

public enum DeliveryStatus: String, Sendable, CaseIterable {
  case pending, executing
  /// 整个操作尚未开始；不能据此恢复目标进程。
  case preparing
  /// 派发已结束，正在从真实历史核对；不是执行成功的证据。
  case confirming
  /// 可能已交出但无法确认；不再领取，只能由真实消息等正证据收敛。
  case unconfirmed
  case succeeded
  case failed = "not_delivered"
}

extension DeliveryStatus {
  static let waiting: Set<DeliveryStatus> = [.pending, .preparing]
  static let waitingSQL = sqlList(waiting.sorted { $0.rawValue < $1.rawValue })
  /// 是否仍在等进度由 Speech 连同期限推出；`DeliveryRequest.isOpen` 与 SQL 的 `openSQL` 都从这里来。
  static let open: Set<DeliveryStatus> = waiting.union([.executing, .confirming])
  static let openSQL = sqlList(open.sorted { $0.rawValue < $1.rawValue })
}

/// 读到本版本不认识的值（`Open.unknown`）时 Mac 端不执行它。
public enum DeliveryMode: String, Sendable, CaseIterable {
  /// 你说的话（唯一一种）：会话歇着就以它开新一轮，在跑就先打断这一轮再开（忙不忙以 Mac 执行时的会话为准，写请求时看到的状态可能已经过时）。没有排队；未确认不自动重发。
  /// 用提示词模板或技能说的（`/名字 …`，回复框按 `PiSlash.speaks` 认）也是它：由 Agent 展开，展开后的那条消息带着请求 id
  case send
  /// 撤回另一条尚未派发的投送；正文为原请求 id，由执行 Mac 原子核对后处理。
  case withdraw
  case answer
  /// 在 Mac 上开一个新会话（后台托管）
  case start
  /// 请 Mac 从会话文件把这个会话的对话补写进来（7 天前活跃过的会话，手机打开时发）
  case transcript
  case config
  /// 结束会话（Pi 进程正常收尾退出，会话记录与会话文件都留着）
  case end
  /// 停止会话正在跑的这一轮（相当于在 Pi 里按 Esc：只停指挥官自己这一轮，子代理不动），会话回到等你下一句
  case stop
  /// 只停止正文指定的投送所开启的回合；Agent 接收端核对身份后同步停止。旧 Mac 不认识此方式，明确拒绝，不退化为 stop。
  case stopTurn
  /// 接着会话出错的那一轮重试（`PiSessionState.canRetry`）：不补发用户消息，也不发“继续”。
  /// 会话在跑或最后一轮不是出错结束的，扩展拒绝（`nothing_to_retry`）
  case retry
  /// 请 Mac 给项目绑定文件夹（或解除绑定）
  case bind
  /// 斜杠命令：正文是以 / 开头的整行，由 Agent 执行；以 Agent 可证实的受理为送达（Pi 执行了扩展命令、压缩做完；OpenCode 的模板经它的命令端点，端点执行完才回，`PiSlash.speaks`）。
  /// 不是“你说的话”：不在对话里挂气泡，带着卡片时只把卡片关联到会话；结果若在会话文件里（压缩）对话里自然有
  case command
  /// 请 Mac 刷新订阅额度：由 Mac 上能答额度的会话里的扩展查一次（`AccountQuota`），新值随同步回来；查不到时照常按失败写回（原因写进手机额度明细的那一行，不弹提示），读数仍是上次的值与更新时间
  case quota
  /// 整理技能与规则：由 Mac 照执行时的文件做，那件已不在的不做
  case tidy
  /// 改一份技能或规则文件：Mac 上的文件已不是基准就退回“Mac 上刚改过”
  case libraryEdit

  public static let requiresReadySession: Set<DeliveryMode> = [.send, .answer, .command, .config, .retry]

  /// 会话的显示状态只把这几种算进去。命令与设置不在其中：对话只来自会话文件，进度只在回复框上方短暂显示。
  public static let toSession: Set<DeliveryMode> = [.send, .answer, .retry]

  /// 内容会落成会话里的一条消息的方式：靠那条消息确认送达，也靠那条消息记发送记录。
  /// 不写 `default`：新增一种方式时编译器逼着在这里表态。
  public var landsAsMessage: Bool {
    switch self {
    case .send, .start: true
    case .withdraw, .answer, .transcript, .config, .end, .stop, .stopTurn, .retry, .bind, .command, .quota, .tidy, .libraryEdit: false
    }
  }

  static let landsAsMessageSQL = sqlList(allCases.filter(\.landsAsMessage).sorted { $0.rawValue < $1.rawValue })
}

/// 请求是谁写的：没有值是你（界面或命令行）；Cue 写的标 `cue`。
public enum DeliveryOrigin: String, Sendable, CaseIterable {
  case cue
}

/// 派发期限只有一个锚点 `serverAt`，两种等待（`pending`、`preparing`）都守它、不续；执行的 Mac 缺附件时仍是 `pending`、在旁边取。
/// 发送方到期仍没收到结果只结束等待、显示未确认：旧快照不能证明 Mac 没领取，不能授权安全重发。
public struct DeliveryRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var target: SendTarget
  /// 指定执行的 Mac，只有它会领取。
  public var hostID: String
  public var mode: Open<DeliveryMode>
  public var cardID: UUID?
  public var status: Open<DeliveryStatus>
  /// 准备、失败或未确认的说明；读 `failure` / `Speech.trip`。
  public var reason: ShownText?
  public var handledBy: String?
  public var createdAt: Date
  public var completedAt: Date?
  /// 领取后的执行、确认阶段的硬截止：进入阶段时写，不随同步、绑定或重开续期。等派发的期限不在这里。
  public var deadlineAt: Date? = nil
  public var modifiedAt: Date
  /// 本机时钟；只在本机，不同步。
  public internal(set) var resultReceivedAt: Date?
  /// 派发期限的锚点：服务器收下它的时刻（CloudKit 记录的 creationDate，服务器的钟）——拉到它的一方从拉到的记录记下，写它的一方从上传成功带回的记录记下，两边是同一个值；
  /// Mac 写给自己、还没传上去的由执行器按写下的时刻锚定。只填空，一经写下不再变。
  /// 不按写下时刻算：手机离线时写下、连上才传上去的照常送到，写方与 Mac 的钟差也不混进来；还没到服务器的不算到期，可以撤回。
  public internal(set) var serverAt: Date? = nil
  public var origin: Open<DeliveryOrigin>?
  /// 读的时候由同步元数据推出，不存（`Speech.reachedServerSQL`）。
  public internal(set) var reachedServer = false
  public internal(set) var sessionBindingRevision: SessionBindingRevision?

  /// 仅领取返回的执行上下文携带：本次结束覆盖的请求身份，重启/同步读取不重建，不持久化。
  public internal(set) var coveredEndRequests: Set<UUID> = []

  public var isFromCue: Bool { origin == .known(.cue) }

  /// 持久记录还没有收尾，不等于此刻在跑；当前进度与控制去重读 Speech.trip。
  public var isOpen: Bool { status.known.map(DeliveryStatus.open.contains) ?? false }

  /// 尚未领取只是撤回的必要条件；能否撤回还要由库事务核对已发送事实。
  public var isWithdrawable: Bool { status.known.map(DeliveryStatus.waiting.contains) == true && handledBy == nil }

  /// 明确未交出的原因；未知状态不是未送达。缺少原因的明确失败只在这里兜底。
  public var failure: String? {
    guard status == .known(.failed) else { return nil }
    guard let reason = reason?.text, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.unexplainedFailure }
    return reason
  }

  /// 等派发与执行两个阶段各用这个时长；留足手机传大附件、Mac 等会话就绪的时间。
  public static let phaseLimit: TimeInterval = 600

  /// 还没有锚点的为 nil，不算到期。派发期限只有这一个出处，SQL 里是 `dispatchDeadlineSQL`。
  public var dispatchDeadline: Date? { serverAt.map { $0.addingTimeInterval(Self.phaseLimit) } }

  /// 毫秒；没有锚点为 NULL（比较都不成立：不领取、不到期）。
  static func dispatchDeadlineSQL(_ alias: String) -> String {
    "(\(alias).serverAt + \(Int(phaseLimit * 1000)))"
  }

  /// 执行的 Mac 写回的到期原因，带着当时在等什么（`reason`）；准备就绪（`DeliveryPreparation.ready`）不是在等什么。
  public var expiry: ShownText {
    guard status == .known(.preparing), let waiting = reason, waiting != DeliveryPreparation.ready else { return ShownText("到期仍未派发，没有发出，可以重发") }
    return ShownText("到期仍未派发（\(waiting.embedded)），没有发出，可以重发")
  }

  public static var interruptedReason: ShownText { ShownText("Mac 上的 CuePad 在执行过程中退出，送达尚未确认，不会自动重发") }

  public static var unexplainedFailure: String { String(localized: "Mac 没有说明原因") }

  /// `requests` 先发的在前。只显示还在路上的，或没能结束且之后没再发过别的；结束成功、未确认或没请求过是 nil。
  public static func shownEnd(in requests: [DeliveryRequest], at moment: Speech.Moment) -> Speech.Trip? {
    guard let end = requests.last(where: { $0.mode == .known(.end) }) else { return nil }
    switch Speech.trip(end, at: moment) {
    case .preparing(let reason): return .preparing(reason)
    case .sending: return .sending
    case .sent: return .sent
    case .delivered, .unconfirmed: return nil
    case .failed(let failure): return end.id == requests.last?.id ? .failed(failure) : nil
    }
  }

  /// `launch`、`bind`、`tidyOrders`、`libraryEdit`、`answer`、`config` 按 `mode` 取请求的内容；其他方式、读不出的为 nil。
  public var launch: PiLaunch? { mode == .known(.start) ? PiLaunch(stored: content) : nil }

  /// 开工的是开场的话里的。写下时登记附件记录、执行的 Mac 取文件、回收附件时算引用，都只读这里。
  public var attachmentKeys: [String] { CueFormat.attachmentKeys(in: launch?.prompt ?? content) }

  public var bind: PiBind? { mode == .known(.bind) ? PiBind(stored: content) : nil }

  public var tidyOrders: [TidyOrder]? { mode == .known(.tidy) ? JSONColumn.decode([TidyOrder].self, from: content) : nil }

  public var libraryEdit: LibraryEdit? { mode == .known(.libraryEdit) ? LibraryEdit(stored: content) : nil }

  public var answer: PiAnswer? { mode == .known(.answer) ? PiAnswer(stored: content) : nil }

  public var config: PiConfig? { mode == .known(.config) ? PiConfig(stored: content) : nil }

  public var isRename: Bool { config?.name != nil }

  /// `requests` 按发出先后（`deliveryRequests(toSession:)` 的顺序）。会话行与会话页顶栏都按它显示名字，取法只此一处。
  public static func latestRename(in requests: [DeliveryRequest]) -> DeliveryRequest? { requests.last(where: \.isRename) }

  /// 两端都是发起设备的时钟；执行方与还没收到结果时为 nil。
  public var roundTrip: Duration? {
    resultReceivedAt.map { .milliseconds(Int64(($0.timeIntervalSince(createdAt) * 1000).rounded())) }
  }
}

/// 未知只能由真实消息等正证据收敛，不授权再次派发。
public enum DeliveryOutcome: Sendable {
  case succeeded
  /// 核对在执行通道之外运行；传入的是已落盘的阶段与期限，不得再次派发。
  case confirming(@Sendable (DeliveryRequest) async -> DeliveryOutcome)
  case failed(ShownText)
  case unconfirmed(ShownText)
}

extension DeliveryRequest: Record {
  static let table = Table.deliveryRequests
  static let columns = [
    "id", "content", "targetKind", "targetName", "targetRef", "hostID", "mode", "cardID", "status",
    "failure", "handledBy", "createdAt", "completedAt", "modifiedAt", "resultReceivedAt", "origin", "serverAt", "deadlineAt", "sessionBindingRevision",
  ]
  static let syncedColumns = columns.filter { !["resultReceivedAt", "serverAt"].contains($0) }
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
