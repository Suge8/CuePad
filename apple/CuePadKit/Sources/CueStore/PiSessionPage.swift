import Foundation

/// 会话按状态分的范围：在线的（未结束）、已结束的（含历史）、全部；`current` 是此刻有事的——在线的，加上已结束但还有话发给它的
/// （在唤醒、没能送达；投送请求了结后不久就被清理，所以只有这几条），项目的"此刻"读它。
public enum PiSessionScope: Sendable, Equatable {
  case live, ended, all, current
}

/// 一台 Mac 上一个文件夹里跑过的 Agent 会话（`CueStore.sessionFolders`）：`sessionID` 与 `projectID` 是其中最近那个会话的。
public struct SessionFolder: Sendable, Equatable {
  public var hostID: String
  public var folder: String
  public var sessionID: String
  public var projectID: UUID?
  public var count: Int
  /// 那台 Mac 给人看的名字（`MacAgents.shownName`，读出时取）。
  public var macName: String

  public init(hostID: String, folder: String, sessionID: String, projectID: UUID?, count: Int, macName: String) {
    self.hostID = hostID
    self.macName = macName
    self.folder = folder
    self.sessionID = sessionID
    self.projectID = projectID
    self.count = count
  }
}

/// 会话列表的一页（Mac 与手机共用的唯一查询，见 `CueStore.piSessionPage`）。条件之间是"且"。
/// 历史会话有几千条：界面只读需要的范围与页，不整表读。
public struct PiSessionQuery: Sendable, Equatable {
  public var scope: PiSessionScope
  /// 在会话名、文件夹名、最后的提问里找（不分大小写）；nil 或空白表示全部。
  public var text: String?
  /// 只要归在这个项目的（`PiSessionListItem.home`）；nil 表示不限。
  public var project: UUID?
  /// 只要带这个认领标识的（新会话认领用，精确取一条）。
  public var launchToken: String?
  /// 只要这一条记录（`PiSessionState.id`）。
  public var id: UUID?
  /// 只要绑在置顶任务上的（true）或其余的（false）；nil 表示不限。
  public var pinned: Bool?
  /// 不要这些会话（Pi 的会话 id）：库里认不出、要按此刻算的（"更早"不列正在唤醒的，`PiSessionList.earlier`）。
  public var excluding: [String] = []
  public var offset: Int
  /// 一页多少条；`Int.max` 表示不分页（只用于本就不多的范围，如在线的）。
  public var limit: Int

  public init(
    scope: PiSessionScope = .all, text: String? = nil, project: UUID? = nil, launchToken: String? = nil, id: UUID? = nil,
    pinned: Bool? = nil, offset: Int = 0, limit: Int = 50
  ) {
    self.scope = scope
    self.text = text
    self.project = project
    self.launchToken = launchToken
    self.id = id
    self.pinned = pinned
    self.offset = offset
    self.limit = limit
  }

  /// 全部在线会话（数量少，不分页）。
  public static let live = PiSessionQuery(scope: .live, limit: .max)
  /// 此刻有事的会话（在线的与还有话发给它的已结束会话，数量少，不分页）。
  public static let current = PiSessionQuery(scope: .current, limit: .max)
}

/// 列表里的一个会话、它所属的项目（没有绑定项目或项目已删为 nil；文件夹名在 `state.folder`），
/// 以及发给它的最近一条投送请求（界面据此在 Mac 吸收它之前就显示"发送中"等）。
public struct PiSessionListItem: Identifiable, Sendable, Equatable {
  public var state: PiSessionState
  public var project: Project?
  public var delivery: DeliveryRequest?
  /// 发给它的最近一条改名请求（带名字的配置请求）：改名在路上、没改成都由它推出。
  public var rename: DeliveryRequest?
  /// 发给它、还没有回执或失败了的话（说话的方式，没被领取或失败、还没重发或移除的）：哪几句没能送达按说的话那条规则看此刻（`undelivered`）。
  public var unsettled: [DeliveryRequest]
  /// 绑着它的顶层任务（`CueStore.sessionTasks`）：会话的"置顶"置的是它；没绑还在列表里的任务为 nil。
  public var task: SessionTask?
  public var id: UUID { state.id }
  /// 会话归在哪个项目（会话页按它筛、项目的此刻按它归）：它的项目还在就是它，没有项目或项目已删的归默认项目。
  public var home: UUID { project?.id ?? Project.defaultID }

  public init(
    state: PiSessionState, project: Project? = nil, delivery: DeliveryRequest? = nil, rename: DeliveryRequest? = nil,
    unsettled: [DeliveryRequest] = [], task: SessionTask? = nil
  ) {
    self.state = state
    self.project = project
    self.delivery = delivery
    self.rename = rename
    self.unsettled = unsettled
    self.task = task
  }

  /// 此刻没能送达的话有几句（`Speech`：失败的与超时的）：会话行的标记与会话页顶栏的"N 句没送到"同读这个数。
  public func undelivered(at moment: Speech.Moment) -> Int { Speech.undelivered(unsettled, at: moment) }
}

/// 会话绑着的顶层任务：会话没有自己的置顶，置顶的是这件事（`Card.isPinned`）。
public struct SessionTask: Sendable, Equatable {
  public var id: UUID
  public var isPinned: Bool
  /// 绑着它的那个叶子的标题（`Card.heading`）：会话行、会话条写的名字以它为准，空的写会话自己的名字（任务标题是名字的唯一事实源）。
  public var title: String

  public init(id: UUID, isPinned: Bool, title: String) {
    self.id = id
    self.isPinned = isPinned
    self.title = title
  }
}

/// 一页会话与符合条件的总数。顺序：未结束的在前，各自按进入当前状态的时间从新到旧。
public struct PiSessionPage: Sendable, Equatable {
  public var items: [PiSessionListItem]
  public var total: Int
}
