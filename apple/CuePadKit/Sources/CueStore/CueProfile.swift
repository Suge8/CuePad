import Foundation

public struct CueProfile: Equatable, Sendable {
  public var name: String
  public var hostID: String?
  public var runtime: Open<AgentKind>
  public var model: String?
  public var effort: Open<ThinkingLevel>?
  public var fast: Bool
  public var voice: Open<CueVoice>
  public var enabledAt: Date?
  public var modifiedAt: Date

  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  public var callVoice: CueVoice { voice.known ?? .default }

  public func onDuty(_ state: CueState?, hostOnline: Bool) -> Bool { activeHost != nil && hostOnline && state?.state != .known(.error) }

  public static let defaultName = "Cue"
  public static let recordID = DeterministicID.uuid("cue-profile")
  public static var syncRecordName: String { recordID.uuidString.lowercased() }

  public init(
    name: String = CueProfile.defaultName, hostID: String? = nil, runtime: Open<AgentKind> = .known(.pi), model: String? = nil,
    effort: Open<ThinkingLevel>? = .known(.low), fast: Bool = false, voice: Open<CueVoice> = .known(.default), enabledAt: Date? = nil, modifiedAt: Date = .now
  ) {
    self.name = name
    self.hostID = hostID
    self.runtime = runtime
    self.model = model
    self.effort = effort
    self.fast = fast
    self.voice = voice
    self.enabledAt = enabledAt
    self.modifiedAt = modifiedAt
  }
}

extension CueProfile: Record, SyncedColumns {
  static let table = Table.cueProfile
  static let fields: [Field] = [
    .plain("id"), .encrypted("name"), .plain("hostID"), .plain("runtime"), .encrypted("model"), .encrypted("effort"),
    .plain("enabledAt"), .plain("modifiedAt"), .encrypted("fast"), .encrypted("voice"),
  ]
  var bindings: [any SQLBindable] {
    [Self.recordID, name, hostID, runtime.rawValue, model, effort?.rawValue, enabledAt, modifiedAt, fast ? Int64(1) : Int64(0), voice.rawValue]
  }
  init(row: Row) {
    let name = row.text(1).trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      name: name.isEmpty ? Self.defaultName : name, hostID: row.textOrNil(2), runtime: Open(rawValue: row.text(3)),
      model: row.textOrNil(4), effort: row.textOrNil(5).map(Open.init(rawValue:)), fast: row.int(8) == 1,
      voice: row.textOrNil(9).map(Open.init(rawValue:)) ?? .known(.default), enabledAt: row.dateOrNil(6), modifiedAt: row.date(7))
  }
}

public enum CueEnableError: LocalizedError, Equatable {
  case noRuntime(String)
  case runsElsewhere(String)
  case unsynced
  case noMac

  public var errorDescription: String? {
    switch self {
    case .noRuntime(let why): String(localized: "没有能当 Cue 的 Agent：\(why)")
    case .runsElsewhere(let name): String(localized: "正在「\(name)」上运行，改过来要先确认")
    case .unsynced: String(localized: "还没和 iCloud 同步完")
    case .noMac: String(localized: "还没有哪台 Mac 可以运行 Cue")
    }
  }
}
