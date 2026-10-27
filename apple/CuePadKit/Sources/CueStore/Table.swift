/// 可观察的表；`CueStore.observe` 按它们订阅变更。
public enum Table: String, Codable, Sendable, CaseIterable {
  case projects, cards, sendRecords, attachments, piSessions, projectDirectories
  case piSessionStates, agentCatalogs, deliveryRequests, directoryBindings, piMessages, previews, accountQuotas
  case cueMessages, cueLines, cueProfile, cueState, cueRead, cueSummaries, macPresence, macAgents, sessionViewers, agentLibraries, agentLibraryFiles
  /// 本机写入序号（`CueStore.lastWrite`，由触发器随 Cue 关心的那几列变化而加）：订阅读它，就只在这些变化时被叫醒。
  case writeCounter
  /// 同步元数据（本机表，`Schema.syncRecordsTable`）：说的话读服务器收下过没有（`Speech.reachedServerSQL`）；订阅只按行依赖还没发出的那几句（`CueStore.dependOnUnsent`）。
  case syncRecords
}

extension Table {
  /// 进入 iCloud 同步的表；其余是本机表。
  package static let synced: [Table] = [
    .projects, .cards, .sendRecords, .attachments, .piSessionStates, .agentCatalogs, .deliveryRequests, .directoryBindings, .piMessages,
    .previews, .accountQuotas,
    .cueMessages, .cueLines, .cueProfile, .cueState, .cueRead, .macPresence, .macAgents, .sessionViewers, .agentLibraries,
    .agentLibraryFiles,
  ]

  /// 带手机通知标志（明文列 `notify`）的表：标志上传即清、远端带回来的不留（`CueStore.markPushed`、`applyVersion`）。
  package static let notifyFlagged: Set<Table> = [.piSessionStates, .cueMessages]

  /// 每张表的列：同步表（`synced`）是同步的那些（CKRecord 的字段），不含它们的本机列（`Schema` 头注释）；本机表是它自己的列。
  package var columns: [String] {
    switch self {
    case .projects: Project.columns
    case .cards: Card.columns
    case .sendRecords: SendRecord.columns
    case .attachments: Attachment.columns
    case .piSessions: IndexedSession.columns
    case .projectDirectories: ["projectID", "directory"]
    case .piSessionStates: PiSessionState.columns
    case .agentCatalogs: AgentCatalog.columns
    case .deliveryRequests: DeliveryRequest.syncedColumns
    case .directoryBindings: DirectoryBinding.columns
    case .piMessages: PiChatMessage.columns
    case .previews: PiPreview.columns
    case .accountQuotas: AccountQuota.columns
    case .cueMessages: CueMessage.columns
    case .cueLines: CueMemoryLine.columns
    case .cueProfile: CueProfile.columns
    case .cueState: CueState.columns
    case .cueRead: CueRead.columns
    case .macPresence: MacPresence.columns
    case .macAgents: MacAgents.columns
    case .agentLibraries: AgentLibrary.columns
    case .agentLibraryFiles: LibraryFileText.columns
    case .sessionViewers: Viewer.columns
    case .cueSummaries: ["lo", "hi", "text", "lineIDs", "createdAt"]
    case .writeCounter: ["seq"]
    case .syncRecords: ["recordName", "recordType", "systemFields", "pushedModifiedAt", "sentModifiedAt"]
    }
  }
}

/// 表行与列的对应。`bindings[0]` 是主键；`columns` 与 `bindings`、`init(row:)` 的读取序号一致。
protocol Record: Sendable {
  static var table: Table { get }
  static var columns: [String] { get }
  /// 读出时 SELECT 的列：默认就是 `columns`；有推出来的字段的记录在后面加上。
  static var selection: String { get }
  var bindings: [any SQLBindable] { get }
  init(row: Row)
}

extension Record {
  static var selection: String { columns.joined(separator: ", ") }
}
