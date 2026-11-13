public enum Table: String, Codable, Sendable, CaseIterable {
  case projects, cards, sendRecords, attachments, piSessions, projectDirectories
  case piSessionStates, agentCatalogs, deliveryRequests, directoryBindings, piMessages, previews, accountQuotas
  case cueMessages, cueLines, cueProfile, cueState, cueRead, cueSummaries, macPresence, macAgents, sessionViewers, agentLibraries, agentLibraryFiles
  case activityDestinations
  /// 本机写入序号（`CueStore.lastWrite`，由触发器随 Cue 关心的那几列变化而加）：订阅读它，就只在这些变化时被叫醒。
  case writeCounter
  /// 同步元数据（本机表，`Schema.syncRecordsTable`）：说的话读服务器收下过没有（`Speech.reachedServerSQL`）；订阅只按行依赖还没发出的那几句（`CueStore.dependOnUnsent`）。
  case syncRecords
}

extension Table {
  package static let synced: [Table] = [
    .projects, .cards, .sendRecords, .attachments, .piSessionStates, .agentCatalogs, .deliveryRequests, .directoryBindings, .piMessages,
    .previews, .accountQuotas,
    .cueMessages, .cueLines, .cueProfile, .cueState, .cueRead, .macPresence, .macAgents, .sessionViewers, .agentLibraries,
    .agentLibraryFiles, .activityDestinations,
  ]

  /// 写完要马上传的（同步层自己传，写的人不用叫）：别的设备在等着办、等着看、等着据此让位或推送的；其余由后台那一路攒批。
  /// 值是这张表里哪些待推送的版本要马上传（`Urgency`）；这些表里的删除都马上传。
  /// 投送请求被 Mac 领下、正在办的那几版（预留、执行）不急：多数几十毫秒就有结果，只传结果那一版，领取那一版在路上会让结果多等一个来回；
  /// 执行久了才先传领取（`DeliveryExecutor.claimGrace`）。
  /// 会话状态只有带手机通知标志的那一版：排在其余待推送后面，等的时候状态前进会把它作废（`StateRecorder`）。
  /// Cue 的状态只在留给你回的变了时：一轮里一步步的经过、上下文由后台那一路带；Cue 的话连同它此刻的状态一起到，只传话手机上会看到话却还显示上一步。
  package static let urgent: [Table: Urgency] = [
    .deliveryRequests: .when("t.handledBy IS NULL OR t.status NOT IN ('preparing', 'executing')"),
    .piSessionStates: .when("t.notify IS NOT NULL"),
    .cueState: .changed("leftToYou", along: .cueMessages),
    .cueMessages: .always, .cueLines: .always, .cueProfile: .always, .macPresence: .always, .sessionViewers: .always,
    .activityDestinations: .always, .macAgents: .always, .agentLibraries: .always, .agentLibraryFiles: .always,
  ]

  package enum Urgency: Sendable {
    case always
    /// 待推送的这一版满足这个 SQL 条件（表别名 `t`）
    case when(String)
    /// 这次写入改了这一列（写事务里比前后，`CueStore.write`），或同一次写入里 `along` 有要马上传的。
    /// 每个写事务开头全表读一遍这一列，只给只有几行的表用。别的进程写的比不了前后，只按 `along` 算。
    case changed(String, along: Table)
  }

  /// 带手机通知标志（明文列 `notify`）的表：标志上传即清、远端带回来的不留（`CueStore.markPushed`、`applyVersion`）。
  package static let notifyFlagged: Set<Table> = [.piSessionStates, .cueMessages]

  /// 每张表的列：同步表（`synced`）是同步的那些（CKRecord 的字段，`syncedFields`）；本机表是它自己的列。
  package var columns: [String] {
    switch self {
    case .piSessions: IndexedSession.columns
    case .projectDirectories: ["projectID", "directory"]
    case .cueSummaries: ["lo", "hi", "text", "lineIDs", "createdAt"]
    case .writeCounter: ["seq"]
    case .syncRecords: ["recordName", "recordType", "systemFields", "pushedModifiedAt", "sentModifiedAt"]
    default: syncedFields.map(\.name)
    }
  }

  package var syncedFields: [Field] { fields.filter { $0.storage != .local } }

  /// 同步表里只留本机的列：记录类型读写的标 `.local`，其余（触发器、单独的 SQL 维护的）列在这里。
  package var localColumns: [String] {
    let maintained: [String] =
      switch self {
      case .cards, .piSessionStates, .cueMessages: ["writeSeq"]  // 本机写入序号，见 `writeSeq`
      case .deliveryRequests: ["writeSeq", "cueToldAt"]  // cueToldAt：Cue 已知道没送到
      case .attachments: ["registeredHere"]  // 这台设备登记的，见 `registerAttachment`
      case .piMessages: ["arrival"]  // 读进这台的次序，这张表的主键让给了它、id 改由 UNIQUE 守，见 `messageArrivalUpgrade`
      case .accountQuotas: ["owners"]
      default: []
      }
    return fields.filter { $0.storage == .local }.map(\.name) + maintained
  }

  /// 同步表的每一列与它的去向；本机表没有。
  private var fields: [Field] {
    switch self {
    case .projects: Project.fields
    case .cards: Card.fields
    case .sendRecords: SendRecord.fields
    case .attachments: Attachment.fields
    case .piSessionStates: SessionState.fields
    case .agentCatalogs: AgentCatalog.fields
    case .deliveryRequests: DeliveryRequest.fields
    case .directoryBindings: DirectoryBinding.fields
    case .piMessages: ChatMessage.fields
    case .previews: PreviewItem.fields
    case .accountQuotas: AccountQuota.fields
    case .cueMessages: CueMessage.fields
    case .cueLines: CueMemoryLine.fields
    case .cueProfile: CueProfile.fields
    case .cueState: CueState.fields
    case .cueRead: CueRead.fields
    case .macPresence: MacPresence.fields
    case .macAgents: MacAgents.fields
    case .agentLibraries: AgentLibrary.fields
    case .agentLibraryFiles: LibraryFileText.fields
    case .sessionViewers: Viewer.fields
    case .activityDestinations: ActivityDestination.fields
    case .piSessions, .projectDirectories, .cueSummaries, .writeCounter, .syncRecords: []
    }
  }
}

/// 同步表的一列：进 CKRecord 的明文字段（结构性的：排序键、时间、引用、标志）、加密字段（用户内容，服务器看不见、不能查询），或只留本机。
/// 没有默认值：加列时必须选，选错的内容以明文进 iCloud，生产环境改不回来。
package struct Field: Sendable {
  package enum Storage: Sendable { case plain, encrypted, local }
  package let name: String
  package let storage: Storage

  static func plain(_ name: String) -> Field { Field(name: name, storage: .plain) }
  static func encrypted(_ name: String) -> Field { Field(name: name, storage: .encrypted) }
  static func local(_ name: String) -> Field { Field(name: name, storage: .local) }
}

/// 同步表的记录类型：列连同去向只在 `fields` 声明一次，SQL 读写的 `columns` 由它推出（顺序即 `bindings`、`init(row:)` 的序号）。
protocol SyncedColumns {
  static var fields: [Field] { get }
}

extension SyncedColumns {
  static var columns: [String] { fields.map(\.name) }
}

/// 表行与列的对应。`bindings[0]` 是主键；`columns` 与 `bindings`、`init(row:)` 的读取序号一致。
protocol Record: Sendable {
  static var table: Table { get }
  static var columns: [String] { get }
  static var selection: String { get }
  var bindings: [any SQLBindable] { get }
  init(row: Row)
}

extension Record {
  static var selection: String { columns.joined(separator: ", ") }
}
