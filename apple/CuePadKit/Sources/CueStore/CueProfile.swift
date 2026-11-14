import Foundation

public struct CueProfile: Equatable, Sendable {
  public var name: String
  public var hostID: String?
  public var runtime: Open<AgentKind>
  public var model: String?
  /// 全新的设置是低（大脑默认要快）；nil 是交给运行时取档。
  public var effort: Open<ThinkingLevel>?
  public var fast: Bool
  public var voice: Open<CueVoice>
  public var enabledAt: Date?
  public var modifiedAt: Date

  /// 在值班的那台 Mac：启用了才有（停用后 `hostID` 还留着，但谁都不该再替 Cue 派活）。
  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  public var callVoice: CueVoice { voice.known ?? .default }

  /// 唯一规则：启用了，运行它的那台 Mac 在线，大脑也没停在起不来（`state` 不是出错）。值班时会话等的回答 CuePad 答得了就归 Cue，不算等你（`SessionState.asksYou`）。
  public func onDuty(_ state: CueState?, hostOnline: Bool) -> Bool { activeHost != nil && hostOnline && state?.state != .known(.error) }

  public static let defaultName = "Cue"
  public static let recordID = DeterministicID.uuid("cue-profile")
  /// 它在 CloudKit 里的记录名（通知服务扩展取 Cue 的名字用）。
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
  /// 这台的库还没和 iCloud 对过一遍：不知道 Cue 是否已在别的 Mac 上启用（App 层判断，`AppServices.enableCue`）
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
