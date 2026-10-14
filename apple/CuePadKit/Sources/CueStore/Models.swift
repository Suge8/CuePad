import Foundation

/// 投送请求与发送记录的目标种类。发出去的只有一种：发给 Agent 会话；发送记录只会是它。
public enum SendTargetKind: String, Sendable, CaseIterable {
  case piSession
  /// 那台 Mac 上的 CuePad 本身：绑定文件夹、连接测试这类不发给会话的请求（执行器不看目标）。存储与同步的字面值沿用 "app"。
  case mac = "app"
}

/// 可观察的表；`CueStore.observe` 按它们订阅变更。
public enum Table: String, Codable, Sendable, CaseIterable {
  case projects, cards, sendRecords, attachments, piSessions, projectDirectories
  case piSessionStates, deliveryRequests, directoryBindings, piMessages, previews, accountQuotas
  case cueMessages, cueLines, cueProfile, cueSummaries
}

extension Table {
  /// 进入 iCloud 同步的表；其余是本机表。
  package static let synced: [Table] = [
    .projects, .cards, .sendRecords, .attachments, .piSessionStates, .deliveryRequests, .directoryBindings, .piMessages, .previews,
    .accountQuotas,
    .cueMessages, .cueLines, .cueProfile,
  ]

  /// 带手机通知标志（明文列 `notify`）的表：标志上传即清、远端带回来的不留（`CueStore.markPushed`、`applyVersion`）。
  package static let notifyFlagged: Set<Table> = [.piSessionStates, .cueMessages]

  /// 远端记录没有这些列（更早的版本写的）时本机落的值：NOT NULL 的列不能写 NULL。
  var missingDefaults: [String: SQLValue] {
    switch self {
    case .cards: ["cueFollows": .int(0)]
    default: [:]
    }
  }

  /// 同步的列（CKRecord 的字段）；不含本机列。
  package var columns: [String] {
    switch self {
    case .projects: Project.columns
    case .cards: Card.columns
    case .sendRecords: SendRecord.columns
    case .attachments: Attachment.columns
    case .piSessions: IndexedSession.columns
    case .projectDirectories: ["projectID", "directory"]
    case .piSessionStates: PiSessionState.columns
    case .deliveryRequests: DeliveryRequest.syncedColumns
    case .directoryBindings: DirectoryBinding.columns
    case .piMessages: PiChatMessage.columns
    case .previews: PiPreview.columns
    case .accountQuotas: AccountQuota.columns
    case .cueMessages: CueMessage.columns
    case .cueLines: CueMemoryLine.columns
    case .cueProfile: CueProfile.columns
    case .cueSummaries: ["lo", "hi", "text", "lineIDs", "createdAt"]
    }
  }
}

/// 表行与列的对应。`bindings[0]` 是主键；`columns` 与 `bindings`、`init(row:)` 的读取序号一致。
protocol Record: Sendable {
  static var table: Table { get }
  static var columns: [String] { get }
  var bindings: [any SQLBindable] { get }
  init(row: Row)
}

public struct Project: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 不会是空的：写入时空名抛 `blankProjectName`；别处（旧版本、同步）留下的空名读出来是 `untitled`。
  public var name: String
  public var icon: String?
  public var color: String
  public var isPinned: Bool
  /// 可选的一句话介绍（项目页顶栏、书架项目卡）。
  public var intro: String?
  /// 回收站中的项目；其卡片随之进回收站（由项目推导，卡片自身不记）。
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date

  public static let untitled = "未命名项目"
}

/// 唯一的内容记录。界面上叫灵感或任务：同一种记录，差别只是 `todoAt`（"设为任务"时写上，"改回灵感"时清掉）。
/// 灵感没有状态；任务有三态（由开始与完成两个时间推出）、可有下级——步骤（顶层任务下的任务，勾选清单里的一条）与提示词（挂在顶层任务下的灵感，要发给 Agent 的话）；任务的正文只有标题，多出来的话都是提示词（`CueLines.split`）。
/// 结构（上级、要做、状态）对调用方只读，各有专门的方法：`setTodo`、`setStatus`、`moveCard`、`createTask`。
public struct Card: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// nil 表示未分类。
  public internal(set) var projectID: UUID?
  /// 纯字符串正文：分割线为独占行 `---split---`，图片为 `![](cuepad://img/<哈希>)`。
  public var body: String
  /// 资料：项目里长期参考的灵感（项目页任务区下面一组）。字段名沿用同步记录里的 isPinned。
  public var isPinned: Bool
  public var variableValues: [String: String]
  /// 冲突副本指向的原卡：同一张卡在两台设备上离线并发改了正文时，较旧的版本存成一张新卡，指回原卡，
  /// 由用户用 `resolveConflict` 选择保留哪一个。普通卡为 nil。
  public internal(set) var conflictOf: UUID?
  public internal(set) var sortKey: String
  /// 单独删除进回收站的时间；随项目删除的卡为 nil。
  public internal(set) var deletedAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 上级任务；nil 是顶层。只有任务能当上级，任务最多 `maxTaskDepth` 级；上级不在库里或不可见时按顶层看待。
  public internal(set) var parentID: UUID?
  /// "设为任务"的时间：有值是任务，nil 是灵感。
  public internal(set) var todoAt: Date?
  /// 开始做的时间（手动置为进行中、或发给 Agent 时）；回到待办时清空。
  public internal(set) var startedAt: Date?
  public internal(set) var completedAt: Date?
  /// 发给 Agent 的会话（Pi 自己的会话 id），灵感与任务的行据此显示会话此刻的状态。
  public internal(set) var piSessionID: String?
  /// 归档的时刻：做完或不再需要，留着可搜、不占列表；连同下级一起归档、一起取回（`archive` / `unarchive`）。
  public internal(set) var archivedAt: Date?
  /// 这件事由 Cue 跟进（否则是你自己）：只有顶层任务能是真，挂到别的任务下、改回灵感时归零（库里的触发器守住，见 `Schema`）。
  /// 你在 CuePad 里亲自对它的会话说话时也归零（`requestDelivery`）。
  public internal(set) var cueFollows = false

  /// 任务最多两级：任务 → 步骤。提示词（任务下的灵感）只挂在叶子下（`CueStore.promptHome`），不算一级。
  public static let maxTaskDepth = 2

  public var isTask: Bool { todoAt != nil }
  /// 空白：正文只有空白（没有文字也没有图片）。空白灵感离开编辑就不留下（`CueStore.dropIfBlank`），也不计数、不当摘要。
  public var isBlank: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// 任务的三态；灵感为 nil。
  public var status: TaskStatus? {
    guard isTask else { return nil }
    return completedAt != nil ? .done : startedAt != nil ? .inProgress : .todo
  }
}

/// 任务三态。由两个时间推出（唯一事实源）：有完成时间是完成，否则有开始时间是进行中，都没有是待办。
public enum TaskStatus: String, Sendable, CaseIterable {
  case todo, inProgress, done
}

/// 同一项目（nil = 未分类）里某一状态的任务（`CueStore.tasks(_:)`）。
public struct TaskGroup: Equatable, Sendable {
  public let projectID: UUID?
  public internal(set) var tasks: [Card]
}

/// 叶子任务，步骤带着它的上级（能绑会话的 `CueStore.bindableTasks`、绑着会话的 `CueStore.tasks(boundTo:)`）：界面写"上级 · 步骤"。
public struct LeafTask: Identifiable, Equatable, Sendable {
  public let task: Card
  /// 步骤的上级任务；顶层任务为 nil。
  public let parent: Card?
  public var id: UUID { task.id }
}

/// 一组顶层任务按状态的个数（`CueStore.taskCounts`）：给用户看的任务数与完成数都是它。
public struct TaskCounts: Equatable, Sendable {
  public var inProgress: Int
  public var todo: Int
  public var done: Int

  public init(inProgress: Int, todo: Int, done: Int) {
    self.inProgress = inProgress
    self.todo = todo
    self.done = done
  }

  public static let zero = TaskCounts(inProgress: 0, todo: 0, done: 0)

  public var open: Int { inProgress + todo }

  public static func + (lhs: TaskCounts, rhs: TaskCounts) -> TaskCounts {
    TaskCounts(inProgress: lhs.inProgress + rhs.inProgress, todo: lhs.todo + rhs.todo, done: lhs.done + rhs.done)
  }
}

/// 步骤完成了几个、一共几个（任务的直接步骤，见 `CueStore.subtaskProgress`）。
public struct TaskProgress: Equatable, Sendable {
  public let done: Int
  public let total: Int

  public init(done: Int, total: Int) {
    self.done = done
    self.total = total
  }
}

/// 灵感或任务交给了 Agent 的哪里：一个会话（Pi 会话 id），或正在开的新会话（还没开好、没认领到）。见 `CueStore.handedSessions`。
public enum AgentHandoff: Hashable, Sendable {
  case session(String)
  case launching
}

/// 卡片挂在哪：某项目（nil = 未分类）的顶层，或某条任务下面（项目随它）。
public enum CardSlot: Hashable, Sendable {
  case top(project: UUID?)
  case under(UUID)
}

/// 一次卡片改动的回执：足够原样拨回去的快照，在改动的同一个事务里读到，所以不会和库里的实际写入对不上（`CueStore.undo`）。
public enum CardChange: Sendable, Equatable {
  /// 设为任务（`on`）或改回灵感：改动前的正文与变量取值，拆出的提示词，提上去的下级。
  case todo(id: UUID, on: Bool, body: String, variableValues: [String: String], prompt: UUID?, lifted: [UUID])
  /// 删除：提上去的下级。
  case trash(id: UUID, lifted: [UUID])
  /// 挪动：原来的位置与原来的前一个同级。
  case move(id: UUID, from: CardSlot, after: UUID?)
  /// 灵感挂到已有草稿的叶子上：并进草稿，灵感删掉。带着删掉的灵感整张卡与草稿并之前的正文、变量取值，拨回时原样还原。
  case fold(idea: Card, draft: UUID, body: String, variableValues: [String: String])
  /// 灵感挂到绑了会话的叶子上：绑了会话的叶子不留提示词，灵感删掉，正文由界面接进会话 `session` 的回复框。拨回时灵感原样还原。
  case handed(idea: Card, session: String)
}

public struct SendRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 发送时的内容快照；卡片之后改动或删除都不影响。
  public var content: String
  public var targetKind: Open<SendTargetKind>
  public var targetName: String
  /// Pi 会话 id 或应用 bundle id。
  public var targetRef: String?
  public var cardID: UUID?
  public var sentAt: Date
  public var modifiedAt: Date
  /// 送出它的投送请求（消息的 `PiChatMessage.deliveryID` 与它对上）与请求的来源：请求完成后会被清理，这两项留下来。
  public var deliveryID: UUID?
  public var origin: Open<DeliveryOrigin>?
}

/// 图片附件元数据；文件按内容哈希存在磁盘，缩略图是派生缓存不入库。
public struct Attachment: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var hash: String
  public var byteCount: Int
  public var format: String
  public var createdAt: Date
  public var modifiedAt: Date
}

/// 一个会话索引的写入：索引、检查点（nil：保留已存的）与同一次读会话文件得到的对话（见 `CueStore.upsertPiSessions`）。
public struct PiSessionUpsert: Sendable {
  public var session: IndexedSession
  public var checkpoint: Data?
  public var transcript: PiTranscript?

  public init(session: IndexedSession, checkpoint: Data?, transcript: PiTranscript?) {
    self.session = session
    self.checkpoint = checkpoint
    self.transcript = transcript
  }
}

/// 仅本机：Agent 会话历史索引的一条（会话文件路径与工作目录，OpenCode 的是它数据库里的会话）。检查点（含读取偏移）另存，用 `piCheckpoint(of:)` 读取。不同步。
public struct IndexedSession: Identifiable, Equatable, Sendable {
  public let id: String
  public var path: String
  public var cwd: String
  public var title: String
  public var lastActivityAt: Date
  public var agent: AgentKind

  public init(id: String, path: String, cwd: String, title: String = "", lastActivityAt: Date, agent: AgentKind = .pi) {
    self.id = id
    self.path = path
    self.cwd = cwd
    self.title = title
    self.lastActivityAt = lastActivityAt
    self.agent = agent
  }
}

public struct SendTarget: Equatable, Sendable {
  public var kind: Open<SendTargetKind>
  public var name: String
  public var ref: String?

  public init(kind: Open<SendTargetKind>, name: String, ref: String? = nil) {
    self.kind = kind
    self.name = name
    self.ref = ref
  }

  public init(kind: SendTargetKind, name: String, ref: String? = nil) {
    self.init(kind: .known(kind), name: name, ref: ref)
  }
}

/// 卡片搜索条件。所有条件同时满足；筛选在分页之前生效。
/// 没有关键词、没有任何筛选时列出该范围内的全部卡片（按最近修改）。
public struct SearchQuery: Sendable, ExpressibleByStringLiteral {
  /// 按空白拆成多个词，每个词都要命中（子串，大小写不敏感）。卡片按正文命中；项目名只用于单列的项目结果。
  /// 空表示不按文字过滤。
  public var text: String
  /// 限定所属项目；nil 元素表示未分类；nil 表示不限；空集合无结果。
  public var projects: Set<UUID?>?
  /// true 只要含图片的卡，false 只要不含图片的卡，nil 不限。
  public var hasImages: Bool?
  /// 发送条件：不限、从未发送过、或发送过（可限目标）。
  public var sent: SendCondition
  /// 卡片最近修改时间落在区间内（含两端）。
  public var modifiedIn: ClosedRange<Date>?
  /// true 只搜回收站里的内容（含随项目进回收站的卡片），false 只搜未删除内容。
  public var inTrash: Bool

  public init(
    text: String = "", projects: Set<UUID?>? = nil, hasImages: Bool? = nil, sent: SendCondition = .any,
    modifiedIn: ClosedRange<Date>? = nil, inTrash: Bool = false
  ) {
    self.text = text
    self.projects = projects
    self.hasImages = hasImages
    self.sent = sent
    self.modifiedIn = modifiedIn
    self.inTrash = inTrash
  }

  public init(stringLiteral value: String) { self.init(text: value) }

  var hasCardFilters: Bool { projects != nil || hasImages != nil || sent != .any || modifiedIn != nil }
}

/// 搜索的发送条件。
public enum SendCondition: Equatable, Sendable {
  /// 不限。
  case any
  /// 从未发送过（没有任何关联该卡的发送记录）。
  case never
  /// 至少发送过一次；可限目标种类与名称（名称精确匹配），都省略表示发到哪里都行。
  case sent(kind: Open<SendTargetKind>? = nil, name: String? = nil)
}

/// 一张卡最近一次发送：何时、发给谁。
public struct LastSend: Equatable, Sendable {
  public var sentAt: Date
  public var target: SendTarget

  public init(sentAt: Date, target: SendTarget) {
    self.sentAt = sentAt
    self.target = target
  }
}

public struct SearchResults: Sendable {
  /// 项目名命中的项目；只在有关键词、没有卡片筛选、第一页时返回。
  public var projects: [Project]
  /// 当前页的卡片，按最近修改。
  public var cards: [Card]
  /// 符合条件的卡片总数（不受分页影响）。
  public var totalCards: Int
}

/// 项目（nil = 未分类）的灵感数（散放在列表里的，不含任务、提示词与空白灵感）。
public struct ProjectSummary: Equatable, Sendable {
  public var projectID: UUID?
  public var cardCount: Int
}

public enum CueStoreError: Error, Equatable {
  case notFound
  case blankTaskContent
  case blankProjectName
  case notAnImage
  /// 卡片或任务只能归属存在且未在回收站的项目（或不归属任何项目）。
  case invalidProject
  /// `resolveConflict` 的目标不是冲突副本。
  case notAConflictCopy
  /// 下载的附件内容与其哈希不符。
  case attachmentHashMismatch
  case blankDeliveryContent
  /// 永久删除已完成，但这些哈希的图片文件没能删掉（记录与文件保留）。
  case attachmentFilesNotRemoved([String])
  /// 库文件是更新版本建的，不打开。
  case unsupportedSchemaVersion(Int)
  /// 库文件是更早版本建的，这个版本不再升级旧结构，不打开。
  case schemaTooOld(Int)
  /// 只能挂到存在的任务下，不能挂到自己或自己的下级下。
  case invalidParent
  /// 挂上去后任务会超过 `Card.maxTaskDepth` 级。
  case taskTooDeep
  /// 只能绑在叶子（没有步骤的任务）上；有步骤的任务绑到它的某个步骤上。
  case notALeaf
  /// 灵感没有状态：先"设为任务"。
  case notATask
  /// 预览的文件不存在、读不了或不是文件（参数是它的路径）。
  case previewUnreadable(String)
  /// 预览的文件超过 `PiPreview.maxBytes`。
  case previewTooLarge(limit: Int)
  /// 预览不支持这种文件（参数是扩展名，空为没有扩展名）。
  case previewUnsupported(String)
  /// 资料库文件只能读（多半是 Agent 的沙箱挡住了写入）。
  case readOnlyLibrary
  // 以下除 memoryLineTooLong 外只有 Cue 经 MCP 会碰到：文案直接写给 Cue，说清该怎么办（Cue 的工具原样转给它）。
  /// 叶子还没有会话（参数是叶子标题）。
  case noSession(String)
  /// 叶子已有会话、没有草稿可交，开工无事可做（参数是叶子标题）。
  case alreadyStarted(String)
  case draftNeeded(String)
  case sending(String)
  /// 叶子绑着会话，不留草稿：话在会话里说（参数是叶子标题）。
  case leafHasSession(String)
  /// 有步骤的任务还有这么多步骤没完成，不能整件完成。
  case stepsRemaining(Int)
  /// 正在为叶子开新会话，开好前不再开（参数是叶子标题）。
  case launching(String)
  /// 任务所在的项目没绑文件夹，开不了会话（参数是项目名；未分类为空）。
  case noFolder(String)
  /// 会话此刻没有能从 CuePad 作答的提问。
  case nothingToAnswer
  case cannotStop(String)
  case cannotChangeModel(String)
  /// 答案不在可选的里面（参数是可选的答案）。
  case invalidAnswer([String])
  /// 一条记忆超过 `CueMemoryLine.maxBytes` 字节。
  case memoryLineTooLong(Int)
  /// 摘要的区间不是记忆里对齐的 2 的幂区间。
  case invalidSummaryRange
  /// Cue 没启用（没有 `cueProfile`、停用了或没选住在哪台 Mac）。
  case cueNotEnabled
}

extension CueStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notFound: "找不到这条记录，可能已被删除"
    case .blankTaskContent: "任务内容不能为空"
    case .blankProjectName: "项目名不能为空"
    case .notAnImage: "不是可识别的图片"
    case .invalidProject: "目标项目已不存在或在回收站"
    case .notAConflictCopy: "这条不是冲突副本"
    case .attachmentHashMismatch: "附件内容与其哈希不符"
    case .blankDeliveryContent: "发送内容不能为空"
    case .attachmentFilesNotRemoved(let hashes): "已永久删除，但有 \(hashes.count) 个图片文件没能删掉"
    case .unsupportedSchemaVersion(let version): "资料库由更新版本的 CuePad 建立（结构版本 \(version)），这个版本打不开"
    case .schemaTooOld(let version): "资料库由更早版本的 CuePad 建立（结构版本 \(version)），这个版本不再升级它"
    case .invalidParent: "只能挂到任务下，不能挂到自己或自己的下级下"
    case .taskTooDeep: "任务最多 \(Card.maxTaskDepth) 级（任务 → 步骤）"
    case .notALeaf: "有步骤的任务不直接绑会话，绑到它的某个步骤上"
    case .notATask: "这是灵感，先「设为任务」再改状态"
    case .previewUnreadable(let path): "读不了这个文件（不存在、不是文件或没有权限）：\(path)"
    case .previewTooLarge(let limit): "文件太大，预览上限 \(limit / 1_000_000) MB"
    case .previewUnsupported(let ext): "不支持预览\(ext.isEmpty ? "没有扩展名的文件" : " .\(ext) 文件")，可发：\(PiPreviewKind.supportedList)"
    case .readOnlyLibrary: "资料库是只读的，写不进去"
    case .noSession(let title): "「\(title)」还没有会话：先用 edit 写草稿再 start，草稿会作为第一句"
    case .alreadyStarted(let title): "「\(title)」已有会话：用 say 对它说话"
    case .leafHasSession(let title): "「\(title)」已有会话，不留草稿：用 say 对它说话"
    case .stepsRemaining(let count): "还有 \(count) 个步骤没完成：先 done 做完的步骤，或用 tell 问用户剩下的还做不做"
    case .draftNeeded(let title): "「\(title)」要接着用上一步的会话，但还没有草稿：先用 edit 写草稿再 start，草稿会作为下一句"
    case .sending(let title): "「\(title)」的话正送进上一步的会话：送到后这一步就绑上它，再用 say 说话（peek 看状态）"
    case .launching(let title): "正在为「\(title)」开会话：等它开好（peek 看状态），再用 say 说话"
    case .noFolder(let project):
      project.isEmpty
        ? "这件事在未分类，开不了会话：用 edit 的 project 放进一个绑了文件夹的项目"
        : "项目「\(project)」没绑文件夹，开不了会话：用 tell 请用户在 CuePad 里给它绑一个"
    case .nothingToAnswer: "会话此刻没有等回答的提问（或只能在 Agent 那边答）：用 say 说话"
    case .cannotChangeModel(let title): "「\(title)」的会话换不了模型（这一家在终端里开的会话不能从 CuePad 换）：用 start 带 fresh:true 和 model 开新会话"
    case .cannotStop(let title): "「\(title)」的会话现在停不了：没在跑一轮、在等你回答，或它在终端里开、不能从 CuePad 停止"
    case .invalidAnswer(let options): "答案要是其中之一（原文或从 1 起的序号）：\(options.joined(separator: " / "))"
    case .memoryLineTooLong(let limit): "一条记忆最多 \(limit) 字节（UTF-8）"
    case .invalidSummaryRange: "摘要区间要是记忆里对齐的 2 的幂区间（lo 是 hi - lo 的倍数）：照记忆视图里待合并的块写"
    case .cueNotEnabled: "Cue 没有启用，不能派活：等用户在 CuePad 里重新启用"
    }
  }
}

// MARK: - 行映射

extension Project: Record {
  static let table = Table.projects
  static let columns = ["id", "name", "icon", "color", "isPinned", "deletedAt", "createdAt", "modifiedAt", "intro"]
  var bindings: [any SQLBindable] { [id, name, icon, color, isPinned, deletedAt, createdAt, modifiedAt, intro] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), name: row.text(1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Project.untitled : row.text(1),
      icon: row.textOrNil(2), color: row.text(3),
      isPinned: row.bool(4), intro: row.textOrNil(8),
      deletedAt: row.dateOrNil(5), createdAt: row.date(6), modifiedAt: row.date(7))
  }
}

extension Card: Record {
  static let table = Table.cards
  static let columns = [
    "id", "projectID", "body", "isPinned", "variableValues", "sortKey", "deletedAt", "createdAt", "modifiedAt", "conflictOf",
    "parentID", "todoAt", "startedAt", "completedAt", "piSessionID", "archivedAt", "cueFollows",
  ]
  var bindings: [any SQLBindable] {
    [
      id, projectID, body, isPinned, JSONColumn.encode(variableValues), sortKey, deletedAt, createdAt, modifiedAt, conflictOf,
      parentID, todoAt, startedAt, completedAt, piSessionID, archivedAt, cueFollows,
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), projectID: row.uuidOrNil(1), body: row.text(2), isPinned: row.bool(3),
      variableValues: Self.variables(row.text(4)),
      conflictOf: row.uuidOrNil(9), sortKey: row.text(5), deletedAt: row.dateOrNil(6), createdAt: row.date(7), modifiedAt: row.date(8),
      parentID: row.uuidOrNil(10), todoAt: row.dateOrNil(11), startedAt: row.dateOrNil(12), completedAt: row.dateOrNil(13),
      piSessionID: row.textOrNil(14), archivedAt: row.dateOrNil(15), cueFollows: row.bool(16))
  }

  /// 几乎所有卡片没有变量取值（存成 "{}"），不为它们创建解码器。
  private static func variables(_ stored: String) -> [String: String] {
    stored == "{}" ? [:] : (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
  }
}

extension SendRecord: Record {
  static let table = Table.sendRecords
  static let columns = ["id", "content", "targetKind", "targetName", "targetRef", "cardID", "sentAt", "modifiedAt", "deliveryID", "origin"]
  var bindings: [any SQLBindable] {
    [id, content, targetKind.rawValue, targetName, targetRef, cardID, sentAt, modifiedAt, deliveryID, origin?.rawValue]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), content: row.text(1),
      targetKind: Open(rawValue: row.text(2)), targetName: row.text(3),
      targetRef: row.textOrNil(4), cardID: row.uuidOrNil(5),
      sentAt: row.date(6), modifiedAt: row.date(7),
      deliveryID: row.uuidOrNil(8), origin: row.textOrNil(9).map(Open.init(rawValue:)))
  }
}

extension Attachment: Record {
  static let table = Table.attachments
  static let columns = ["id", "hash", "byteCount", "format", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, hash, byteCount, format, createdAt, modifiedAt] }
  init(row: Row) {
    self.init(id: row.uuid(0), hash: row.text(1), byteCount: Int(row.int(2)), format: row.text(3), createdAt: row.date(4), modifiedAt: row.date(5))
  }
}

extension IndexedSession: Record {
  static let table = Table.piSessions
  static let columns = ["id", "path", "cwd", "title", "lastActivityAt", "agent"]
  var bindings: [any SQLBindable] { [id, path, cwd, title, lastActivityAt, agent.rawValue] }
  init(row: Row) {
    self.init(
      id: row.text(0), path: row.text(1), cwd: row.text(2), title: row.text(3),
      lastActivityAt: row.date(4), agent: row.textOrNil(5).flatMap(AgentKind.init(rawValue:)) ?? .pi)
  }
}

/// 一张卡的冲突：原卡（较新的版本）与冲突副本（较旧的正文）。
public struct CardConflict: Equatable, Sendable {
  public var original: Card
  public var copy: Card
}

public enum ConflictChoice: Sendable {
  /// 保留原卡的正文，删除副本。
  case original
  /// 用副本的正文替换原卡的正文，删除副本。
  case copy
}
