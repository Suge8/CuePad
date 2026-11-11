import Foundation

/// 会话按状态分的范围：在线的（未结束）、已结束的（含历史）、全部；`current` 是此刻有事的——在线的，加上已结束但还有话发给它的
/// （在唤醒、没能送达；投送请求了结后不久就被清理，所以只有这几条），项目的"此刻"读它。
public enum SessionScope: Sendable, Equatable {
  case live, ended, all, current
}

/// 一台 Mac 上一个文件夹里跑过的 Agent 会话（`CueStore.sessionFolders`）：`sessionID` 与 `projectID` 是其中最近那个会话的。
public struct SessionFolder: Sendable, Equatable {
  public var hostID: String
  public var folder: String
  public var sessionID: String
  public var projectID: UUID?
  public var count: Int
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

/// 会话列表的一页（Mac 与手机共用的唯一查询，见 `CueStore.sessionPage`）。条件之间是"且"。
/// 历史会话有几千条：界面只读需要的范围与页，不整表读。
public struct SessionQuery: Sendable, Equatable {
  public var scope: SessionScope
  /// 在会话名、文件夹名、最后的提问里找（不分大小写）；nil 或空白表示全部。
  public var text: String?
  public var project: UUID?
  /// 只要带这个认领标识的（新会话认领用，精确取一条）。
  public var launchToken: String?
  public var id: UUID?
  public var pinned: Bool?
  /// 不要这些会话（Pi 的会话 id）：库里认不出、要按此刻算的（"更早"不列正在唤醒的，`SessionListData.earlier`）。
  public var excluding: [String] = []
  public var offset: Int
  /// 一页多少条；`Int.max` 表示不分页（只用于本就不多的范围，如在线的）。
  public var limit: Int

  public init(
    scope: SessionScope = .all, text: String? = nil, project: UUID? = nil, launchToken: String? = nil, id: UUID? = nil,
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

  public static let live = SessionQuery(scope: .live, limit: .max)
  public static let current = SessionQuery(scope: .current, limit: .max)
}

/// 列表里的一个会话、它所属的项目（没有绑定项目或项目已删为 nil；文件夹名在 `state.folder`），
/// 以及发给它的最近一条投送请求（界面据此在 Mac 吸收它之前就显示"发送中"等）。
public struct SessionListItem: Identifiable, Sendable, Equatable {
  public var state: SessionState
  public var project: Project?
  public var delivery: DeliveryRequest?
  /// 发给它的最近一条改名请求（带名字的配置请求）：改名在路上、没改成都由它推出。
  public var rename: DeliveryRequest?
  /// 发给它的最近一条作答请求：答题部件据此看作答到哪了，别的请求再发进来也不会把它挤掉（`delivery` 只留最近一条）。
  public var answer: DeliveryRequest?
  /// 发给它、还没有回执或失败了的话（说话的方式，没被领取或失败、还没重发或移除的）：哪几句没能送达按说的话那条规则看此刻（`undelivered`）。
  public var unsettled: [DeliveryRequest]
  /// 它此刻归的那件事的顶层任务（`CueStore.sessionOwners`）：会话的"置顶"置的是它；没绑还在列表里的任务为 nil。
  public var task: SessionTask?
  public var id: UUID { state.id }
  public var home: UUID { project?.id ?? Project.defaultID }

  public init(
    state: SessionState, project: Project? = nil, delivery: DeliveryRequest? = nil, rename: DeliveryRequest? = nil, answer: DeliveryRequest? = nil,
    unsettled: [DeliveryRequest] = [], task: SessionTask? = nil
  ) {
    self.state = state
    self.project = project
    self.delivery = delivery
    self.rename = rename
    self.answer = answer
    self.unsettled = unsettled
    self.task = task
  }

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
public struct SessionListPage: Sendable, Equatable {
  public var items: [SessionListItem]
  public var total: Int
}
