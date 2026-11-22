public enum Table: String, Codable, Sendable, CaseIterable {
  case projects, cards, sendRecords, attachments, piSessions, projectDirectories
  case piSessionStates, agentCatalogs, deliveryRequests, directoryBindings, piMessages, previews, accountQuotas
  case cueMessages, cueLines, cueProfile, cueState, marks, cueSummaries, macPresence, macAgents, sessionViewers, agentLibraries, agentLibraryFiles
  case activityDestinations
  case writeCounter
  case syncRecords
  case liveAddresses
}

extension Table {
  package static let synced: [Table] = [
    .projects, .cards, .sendRecords, .attachments, .piSessionStates, .agentCatalogs, .deliveryRequests, .directoryBindings, .piMessages,
    .previews, .accountQuotas,
    .cueMessages, .cueLines, .cueProfile, .cueState, .marks, .macPresence, .macAgents, .sessionViewers, .agentLibraries,
    .agentLibraryFiles, .activityDestinations,
  ]

  package static let live: [Table: Urgency] = [
    .deliveryRequests: .when("t.status != 'executing'"),
    .piSessionStates: .when("t.notify IS NOT NULL"),
    .cueState: .gathered,
    .cueMessages: .always, .cueLines: .always, .cueProfile: .always, .macPresence: .always, .sessionViewers: .always,
    .activityDestinations: .always, .macAgents: .always, .agentLibraries: .always, .agentLibraryFiles: .always,
  ]

  package enum Urgency: Sendable {
    case always
    case when(String)
    case gathered
  }

  package static let notifyFlagged: Set<Table> = [.piSessionStates, .cueMessages]

  package var columns: [String] {
    switch self {
    case .piSessions: IndexedSession.columns
    case .projectDirectories: ["projectID", "directory"]
    case .cueSummaries: ["lo", "hi", "text", "lineIDs", "createdAt"]
    case .writeCounter: ["seq"]
    case .liveAddresses: ["sessionID", "url", "found", "sentAt"]
    case .syncRecords: ["recordName", "recordType", "systemFields", "pushedModifiedAt", "sentModifiedAt"]
    default: syncedFields.map(\.name)
    }
  }

  package var syncedFields: [Field] { fields.filter { $0.storage != .local } }

  package var localColumns: [String] {
    let maintained: [String] =
      switch self {
      case .cards, .piSessionStates, .cueMessages, .marks: ["writeSeq"]
      case .deliveryRequests: ["writeSeq", "cueToldAt"]
      case .attachments: ["registeredHere"]
      case .piMessages: ["arrival"]
      case .accountQuotas: ["owners"]
      default: []
      }
    return fields.filter { $0.storage == .local }.map(\.name) + maintained
  }

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
    case .marks: Mark.fields
    case .macPresence: MacPresence.fields
    case .macAgents: MacAgents.fields
    case .agentLibraries: AgentLibrary.fields
    case .agentLibraryFiles: LibraryFileText.fields
    case .sessionViewers: Viewer.fields
    case .activityDestinations: ActivityDestination.fields
    case .piSessions, .projectDirectories, .cueSummaries, .writeCounter, .syncRecords, .liveAddresses: []
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

protocol SyncedColumns {
  static var fields: [Field] { get }
}

extension SyncedColumns {
  static var columns: [String] { fields.map(\.name) }
}

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
