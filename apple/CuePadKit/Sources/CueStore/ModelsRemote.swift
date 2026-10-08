import Foundation

/// Pi 会话的工作状态。
public enum PiWorkState: String, Sendable, CaseIterable {
  case thinking, outputting, tool, waitingForUser, settled, error
  /// 自己这轮已经歇下，还有子代理在跑：仍在处理
  case delegating
  /// 会话已结束（Pi 退出、换了会话），以及本机会话文件索引里的历史会话：记录留着，会话文件被删时才删。
  case ended

  /// 正在干活（思考、输出、调用工具）。
  public var isWorking: Bool {
    switch self {
    case .thinking, .outputting, .tool, .delegating: true
    case .waitingForUser, .settled, .error, .ended: false
    }
  }

  /// Pi 自己正在跑一轮（含弹窗等你确认）：此时发消息只能马上说或等它做完再说。等子代理不算——指挥官这轮已经歇下，消息直接开始新的一轮。
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

  /// 要不要提示的唯一规则（Mac 置位通知标志、手机在前台读同步来的记录做 App 内提示都用它）：进入等你确认；从工作中进入完成。
  /// 首次看到的会话（没有上一个状态）不提示，重启或重新读取时不会把旧事件再提示一遍。
  public static func entering(_ state: PiWorkState, from previous: PiWorkState?) -> PiAlert? {
    guard let previous else { return nil }
    if state == .waitingForUser, previous != .waitingForUser { return .waitingForUser }
    if state == .settled, previous.isWorking { return .settled }
    return nil
  }
}

extension PiSessionState {
  /// 相对上一次读到的版本（nil：第一次读到），这个版本是不是一次要提示的转换。手机读到的是同步合并后的版本：状态没变而
  /// 状态起点往后走了，说明中间又经过了一轮工作（没读到），按"刚从工作中来"算。
  public func alert(since previous: PiSessionState?) -> PiAlert? {
    guard let previous, let state = state.known else { return nil }
    let before = previous.state.known
    let missedRound = before == state && stateSince > previous.stateSince
    return PiAlert.entering(state, from: missedRound ? .thinking : before)
  }
}

/// 会话记录上的摘要（列表预览、会话页顶部用）：对话（`PiChatMessage`）的投影，由同一个写者（Mac 读会话文件）
/// 在写对话的同一事务里写（`CueStore.writePiTranscript`），界面直接读、不和对话对账。等你回答的弹窗（`question`）
/// 不在对话里，来自 Pi 桥，由状态记录器写。
public struct PiRecap: Sendable, Equatable {
  /// 最近一轮已做完的问答里你说的那句（单行，至多 500 字符）；与 `lastReply` 成对，在这一轮做完时一起更新。
  public var lastPrompt: String?
  /// 最近一轮已做完的问答里助手的最终回答文字（不含思考与工具调用），保留换行，至多 1200 字符。
  public var lastReply: String?
  /// 进行中的提问：你说了、这一轮还没做完（单行，至多 500 字符）；这一轮做完时移进 `lastPrompt`，没有时为 nil。
  /// 界面据此写"你说：… · Pi 正在处理"，上一轮的问答另行折叠，不把新提问和旧回答配在一起。
  public var pendingPrompt: String?

  public init(lastPrompt: String? = nil, lastReply: String? = nil, pendingPrompt: String? = nil) {
    self.lastPrompt = lastPrompt
    self.lastReply = lastReply
    self.pendingPrompt = pendingPrompt
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

/// Pi 的思考强度（Pi 的 `ThinkingLevel`，含关闭）。
public enum PiThinkingLevel: String, Sendable, CaseIterable {
  case off, minimal, low, medium, high, xhigh, max
}

/// 一个模型的标识：提供方加模型 id（同一个 id 可以出自不同提供方）。
public struct PiModelKey: Sendable, Hashable, Codable {
  public var provider: String
  public var id: String

  public init(provider: String, id: String) {
    self.provider = provider
    self.id = id
  }
}

/// 会话可选的一个模型：标识、显示名，以及它支持的思考强度（不支持思考的只有 `off`；不认识的新强度读出时丢掉）。
public struct PiModelOption: Sendable, Equatable, Identifiable {
  public var key: PiModelKey
  public var name: String
  public var thinkingLevels: [PiThinkingLevel]
  public var id: PiModelKey { key }

  public init(key: PiModelKey, name: String, thinkingLevels: [PiThinkingLevel]) {
    self.key = key
    self.name = name
    self.thinkingLevels = thinkingLevels
  }

  private struct Stored: Codable {
    var provider: String
    var id: String
    var name: String
    var thinking: [String]
  }

  private init(_ stored: Stored) {
    self.init(
      key: PiModelKey(provider: stored.provider, id: stored.id), name: stored.name,
      thinkingLevels: stored.thinking.compactMap(PiThinkingLevel.init(rawValue:)))
  }

  private var form: Stored {
    Stored(provider: key.provider, id: key.id, name: name, thinking: thinkingLevels.map(\.rawValue))
  }

  /// 同步记录里存为 JSON（加密字段 `model`、`models`）；读不出的当作没有。
  static func stored(_ option: PiModelOption?) -> String? {
    option.map { String(decoding: try! JSONEncoder().encode($0.form), as: UTF8.self) }
  }

  static func stored(_ list: [PiModelOption]) -> String? {
    list.isEmpty ? nil : String(decoding: try! JSONEncoder().encode(list.map(\.form)), as: UTF8.self)
  }

  static func option(stored: String?) -> PiModelOption? {
    stored.flatMap { try? JSONDecoder().decode(Stored.self, from: Data($0.utf8)) }.map(PiModelOption.init)
  }

  static func list(stored: String?) -> [PiModelOption] {
    stored.flatMap { try? JSONDecoder().decode([Stored].self, from: Data($0.utf8)) }.map { $0.map(PiModelOption.init) } ?? []
  }
}

/// 一个会话此刻的模型配置：当前模型与思考强度、可以换成的模型。Pi 桥上报，状态记录器整体写入。
public struct PiModelState: Sendable, Equatable {
  public var model: PiModelOption?
  public var thinking: Open<PiThinkingLevel>?
  public var models: [PiModelOption]

  public init(model: PiModelOption? = nil, thinking: Open<PiThinkingLevel>? = nil, models: [PiModelOption] = []) {
    self.model = model
    self.thinking = thinking
    self.models = models
  }
}

/// 手机发给 Mac 的会话配置：换模型、改思考强度，至少改一项。存在投送请求（方式 `config`）的正文里（JSON）。
/// 先换模型再设思考强度：强度按新模型支持的范围取。
public struct PiConfig: Sendable, Equatable {
  public var model: PiModelKey?
  public var thinking: PiThinkingLevel?

  public init(model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil) {
    self.model = model
    self.thinking = thinking
  }

  private struct Stored: Codable {
    var model: PiModelKey?
    var thinking: String?
  }

  var stored: String {
    String(decoding: try! JSONEncoder().encode(Stored(model: model, thinking: thinking?.rawValue)), as: UTF8.self)
  }

  /// 什么都不改、或强度是更新版本的新值（本版本不认识）时为 nil。
  init?(stored: String) {
    guard let form = try? JSONDecoder().decode(Stored.self, from: Data(stored.utf8)) else { return nil }
    let thinking = form.thinking.map(PiThinkingLevel.init(rawValue:))
    guard thinking != .some(nil), form.model != nil || thinking != nil else { return nil }
    self.init(model: form.model, thinking: thinking ?? nil)
  }
}

/// 新会话开在哪：某个项目绑定的代码目录，或与某个会话同一目录。手机不传路径，Mac 按本机的绑定与会话索引解析。
public enum PiLaunchPlace: Sendable, Equatable {
  case project(UUID)
  case besideSession(String)
}

/// 在 Mac 上开一个新 Pi 会话（投送方式 `start` 的正文，存为 JSON）：Mac 在后台托管它（Pi 的 RPC 模式，没有终端界面），
/// 开场的话作为第一条消息送入。`token` 由发起方生成，带到新会话的同步记录上（`PiSessionState.launchToken`），发起方据此认领。
public struct PiLaunch: Sendable, Equatable {
  public var place: PiLaunchPlace
  /// 开场的话（可空）。
  public var prompt: String?
  public var token: String

  public init(place: PiLaunchPlace, prompt: String?, token: String) {
    self.place = place
    self.prompt = prompt
    self.token = token
  }

  private struct Stored: Codable {
    var project: UUID?
    var besideSession: String?
    var prompt: String?
    var token: String
  }

  var stored: String {
    var form = Stored(prompt: prompt, token: token)
    switch place {
    case .project(let id): form.project = id
    case .besideSession(let sessionID): form.besideSession = sessionID
    }
    return String(decoding: try! JSONEncoder().encode(form), as: UTF8.self)
  }

  init?(stored: String) {
    guard let form = try? JSONDecoder().decode(Stored.self, from: Data(stored.utf8)),
      let place = form.project.map(PiLaunchPlace.project) ?? form.besideSession.map(PiLaunchPlace.besideSession)
    else { return nil }
    self.init(place: place, prompt: form.prompt, token: form.token)
  }
}

/// 子代理此刻在干什么（同步记录里给手机看的粗状态）。
public enum PiSubagentActivity: String, Sendable, CaseIterable {
  case working, waitingForUser, idle, error
}

/// 会话里的一个子代理：名字与此刻在干什么。
public struct PiSubagentState: Sendable, Equatable {
  public var name: String
  public var activity: Open<PiSubagentActivity>

  public init(name: String, activity: Open<PiSubagentActivity>) {
    self.name = name
    self.activity = activity
  }

  private struct Stored: Codable {
    var name: String
    var activity: String
  }

  /// 同步记录里存为 JSON 数组（加密字段 `subagents`）；读不出的当作没有。
  static func stored(_ list: [PiSubagentState]) -> String? {
    guard !list.isEmpty else { return nil }
    let data = try! JSONEncoder().encode(list.map { Stored(name: $0.name, activity: $0.activity.rawValue) })
    return String(decoding: data, as: UTF8.self)
  }

  static func list(stored: String?) -> [PiSubagentState] {
    guard let stored, let decoded = try? JSONDecoder().decode([Stored].self, from: Data(stored.utf8)) else { return [] }
    return decoded.map { PiSubagentState(name: $0.name, activity: Open(rawValue: $0.activity)) }
  }
}

/// 会话按状态分的范围：在线的（未结束）、已结束的（含历史）、全部。
public enum PiSessionScope: Sendable, Equatable {
  case live, ended, all
}

/// 会话列表的一页（Mac 与手机共用的唯一查询，见 `CueStore.piSessionPage`）。条件之间是"且"。
/// 历史会话有几千条：界面只读需要的范围与页，不整表读。
public struct PiSessionQuery: Sendable, Equatable {
  public var scope: PiSessionScope
  /// 在会话名、文件夹名、最后的提问里找（不分大小写）；nil 或空白表示全部。
  public var text: String?
  /// 只要归入这个项目的；nil 表示不限。
  public var project: UUID?
  /// 只要带这个认领标识的（新会话认领用，精确取一条）。
  public var launchToken: String?
  /// 只要这一条记录（`PiSessionState.id`）。
  public var id: UUID?
  public var offset: Int
  /// 一页多少条；`Int.max` 表示不分页（只用于本就不多的范围，如在线的）。
  public var limit: Int

  public init(
    scope: PiSessionScope = .all, text: String? = nil, project: UUID? = nil, launchToken: String? = nil, id: UUID? = nil,
    offset: Int = 0, limit: Int = 50
  ) {
    self.scope = scope
    self.text = text
    self.project = project
    self.launchToken = launchToken
    self.id = id
    self.offset = offset
    self.limit = limit
  }

  /// 全部在线会话（数量少，不分页）。
  public static let live = PiSessionQuery(scope: .live, limit: .max)
}

/// 列表里的一个会话、它所属的项目（没有绑定项目或项目已删为 nil；文件夹名在 `state.folder`），
/// 以及发给它的最近一条投送请求（界面据此在 Mac 吸收它之前就显示"发送中"等）。
public struct PiSessionListItem: Identifiable, Sendable, Equatable {
  public var state: PiSessionState
  public var project: Project?
  public var delivery: DeliveryRequest?
  public var id: UUID { state.id }

  public init(state: PiSessionState, project: Project? = nil, delivery: DeliveryRequest? = nil) {
    self.state = state
    self.project = project
    self.delivery = delivery
  }
}

/// 一页会话与符合条件的总数。顺序：未结束的在前，各自按进入当前状态的时间从新到旧。
public struct PiSessionPage: Sendable, Equatable {
  public var items: [PiSessionListItem]
  public var total: Int
}

/// 一个 Pi 会话的同步记录，Mac 写、手机与 Mac 的界面都只读它：每个 Pi 会话一条，记录 id 由 Pi 自己的会话 id 算出
/// （会话文件头里的 id，Pi 重启、恢复会话后不变），所以在线与历史是同一条记录的不同状态（历史即 `ended`）。
/// Mac 上在线会话的状态来自 Pi 桥，历史来自本机的会话文件索引；会话文件被删时才删记录。完整路径不同步，只有文件夹名与项目。
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
  /// 摘要，见 `PiRecap`（同名字段）；`question` 是 Pi 此刻弹出、等你回答的对话框。旧版本写的记录没有。
  public var lastPrompt: String?
  public var lastReply: String?
  public var pendingPrompt: String?
  public var question: PiQuestion?
  /// 这次写入是否要通知手机；见 `PiAlert`。
  public var notify: Open<PiAlert>?
  /// 计时基准，见 `PiTimes`（同名字段）。界面：工作中"已运行"自 `busySince`，等你确认"已等"自 `stateSince`，其余"多久前"自 `stateSince`。
  public var stateSince: Date
  /// 旧版本写的记录没有。
  public var busySince: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 由 CuePad 发起的新会话（投送方式 `start`）带着发起方生成的标识（`PiLaunch.start` 的 `token`），
  /// 发起方据此等到并打开"自己开的那个"会话。其余会话为 nil。
  public var launchToken: String?
  /// Mac 在后台替你托管着它（没有终端界面；给已结束的会话发消息、开新会话时由 Mac 自动启动）。这样的会话没有终端可跳。
  public var hosted: Bool
  /// 会话里的子代理（FireCode 等在同一进程里开的子会话），一行一个。
  public var subagents: [PiSubagentState]
  /// 会话当前的模型与思考强度、可以换成的模型（Pi 桥上报；已结束的会话留着最后的模型与强度，可选列表清空）。旧版本写的记录没有。
  public var model: PiModelOption?
  public var thinking: Open<PiThinkingLevel>?
  public var models: [PiModelOption]

  /// 公开给 Mac 端：把桥上的实时会话也写成这种形状，交给同一个近况界面。
  public init(
    id: UUID, sessionID: String, hostID: String, title: String, projectID: UUID?, state: Open<PiWorkState>, detail: String?,
    folder: String?, lastPrompt: String?, lastReply: String?, question: PiQuestion?, notify: Open<PiAlert>?, stateSince: Date,
    busySince: Date?, createdAt: Date, modifiedAt: Date, launchToken: String? = nil, hosted: Bool = false,
    subagents: [PiSubagentState] = [], pendingPrompt: String? = nil, model: PiModelOption? = nil,
    thinking: Open<PiThinkingLevel>? = nil, models: [PiModelOption] = []
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
    self.launchToken = launchToken
    self.hosted = hosted
    self.subagents = subagents
    self.pendingPrompt = pendingPrompt
    self.model = model
    self.thinking = thinking
    self.models = models
  }

  /// 记录上的摘要（对话的投影）。
  public var recap: PiRecap { PiRecap(lastPrompt: lastPrompt, lastReply: lastReply, pendingPrompt: pendingPrompt) }

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

  /// 发给会话本身、会改变它状态的方式（说话与作答）；会话的显示状态只把这几种算进去。
  public static let toSession: Set<DeliveryMode> = [.send, .steer, .followUp, .paste, .answer]
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

  /// 作答请求的答案；其他方式为 nil。
  public var answer: PiAnswer? { mode == .known(.answer) ? PiAnswer(stored: content) : nil }

  /// 配置请求的内容；其他方式为 nil。
  public var config: PiConfig? { mode == .known(.config) ? PiConfig(stored: content) : nil }

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
  /// 对话的投影（见 `PiRecap`），只由 `writePiTranscript` 写
  static let recapColumns: Set<String> = ["lastPrompt", "lastReply", "pendingPrompt"]
  static let columns = [
    "id", "sessionID", "hostID", "title", "projectID", "state", "detail", "stateSince", "createdAt", "modifiedAt", "notify", "folder",
    "lastPrompt", "lastReply", "question", "busySince", "launchToken", "hosted", "subagents", "pendingPrompt",
    "model", "thinking", "models",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, hostID, title, projectID, state.rawValue, detail, stateSince, createdAt, modifiedAt, notify?.rawValue, folder,
     lastPrompt, lastReply, question?.stored, busySince, launchToken, hosted ? Int64(1) : nil, PiSubagentState.stored(subagents), pendingPrompt,
     PiModelOption.stored(model), thinking?.rawValue, PiModelOption.stored(models)]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), sessionID: row.text(1), hostID: row.text(2), title: row.text(3), projectID: row.uuidOrNil(4),
      state: Open(rawValue: row.text(5)), detail: row.textOrNil(6), folder: row.textOrNil(11),
      lastPrompt: row.textOrNil(12), lastReply: row.textOrNil(13), question: row.textOrNil(14).map(PiQuestion.init(stored:)),
      notify: row.textOrNil(10).map(Open.init(rawValue:)), stateSince: row.date(7), busySince: row.dateOrNil(15), createdAt: row.date(8),
      modifiedAt: row.date(9), launchToken: row.textOrNil(16), hosted: row.intOrNil(17) == 1,
      subagents: PiSubagentState.list(stored: row.textOrNil(18)),
      // 列里是会话文件的投影原样（最后一句可能是上次中途退出、没等到回答的）；已结束的会话没有正在处理的提问，
      // 会话重新连上时又是它——不必等文件再追加
      pendingPrompt: row.text(5) == PiWorkState.ended.rawValue ? nil : row.textOrNil(19),
      model: PiModelOption.option(stored: row.textOrNil(20)), thinking: row.textOrNil(21).map(Open.init(rawValue:)),
      models: PiModelOption.list(stored: row.textOrNil(22)))
  }
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

/// 项目在哪台 Mac 上绑定了代码目录（Mac 写、手机读）：每个 (项目, Mac) 一条，只有目录末段名，完整路径只在那台 Mac 本机。
/// 手机据此列出能开新会话的项目，并知道发给哪台 Mac。由 Mac 从本机的目录绑定推导（`CueStore.publishDirectoryBindings`）。
public struct DirectoryBinding: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var projectID: UUID
  public var hostID: String
  /// 那台 Mac 的名字（给人选 Mac 时看）。
  public var hostName: String
  public var folder: String
  public var createdAt: Date
  public var modifiedAt: Date

  static func recordID(project: UUID, host: String) -> UUID { DeterministicID.uuid("directory-binding/\(project.uuidString.lowercased())/\(host)") }
}

extension DirectoryBinding: Record {
  static let table = Table.directoryBindings
  static let columns = ["id", "projectID", "hostID", "hostName", "folder", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, projectID, hostID, hostName, folder, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuid(1), hostID: row.text(2), hostName: row.text(3), folder: row.text(4),
      createdAt: row.date(5), modifiedAt: row.date(6))
  }
}
