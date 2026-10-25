import Foundation

/// Cue 的设置（同步，只有一行）。
public struct CueProfile: Equatable, Sendable {
  public var name: String
  /// 运行在哪台 Mac（`PiSessionState.hostID` 同一种标识）；没选为 nil。
  public var hostID: String?
  /// 大脑跑在哪家 Agent 里（`runtimes` 之一）
  public var runtime: Open<AgentKind>
  /// 大脑用的模型，按 `runtime` 那家的写法（`AgentKind.modelRef`）；nil 是用这家自己的默认。
  public var model: String?
  /// 思考强度：三种运行时都用这一个枚举，各家在大脑里映射。全新的设置是低（大脑默认要快）；nil 是交给运行时取档。
  public var effort: Open<PiThinkingLevel>?
  /// 启用的时刻；nil 是没启用。
  public var enabledAt: Date?
  public var modifiedAt: Date

  /// 在值班的那台 Mac：启用了才有（停用后 `hostID` 还留着，但谁都不该再替 Cue 派活）。
  public var activeHost: String? { enabledAt == nil ? nil : hostID }

  /// Cue 在值班（唯一规则）：启用了，它运行的那台 Mac 在线（`hostOnline`，那台的在线记录 `MacPresence`），大脑也没停在起不来（`state` 不是出错）。
  /// 值班时会话等的回答 CuePad 答得了就归 Cue（`PiSessionState.asksYou`），不算等你；它运行的那台 Mac 的管理器是否在跑由那台的 `activeHost` 定，与这里同源。
  public func onDuty(_ state: CueState?, hostOnline: Bool) -> Bool { activeHost != nil && hostOnline && state?.state != .known(.error) }

  public static let defaultName = "Cue"
  /// 能当大脑的几家，按启用时挑选的顺序（OpenCode 不能当大脑）：Mac 查本机能用的、两端 Cue 页的模型菜单都按它。
  public static let runtimes: [AgentKind] = [.pi, .codex, .claudeCode]
  /// 只有一行：任何设备上都是这个 id。
  public static let recordID = DeterministicID.uuid("cue-profile")
  /// 它在 CloudKit 里的记录名（通知服务扩展取 Cue 的名字用）。
  public static var syncRecordName: String { recordID.uuidString.lowercased() }

  public init(
    name: String = CueProfile.defaultName, hostID: String? = nil, runtime: Open<AgentKind> = .known(.pi), model: String? = nil,
    effort: Open<PiThinkingLevel>? = .known(.low), enabledAt: Date? = nil, modifiedAt: Date = .now
  ) {
    self.name = name
    self.hostID = hostID
    self.runtime = runtime
    self.model = model
    self.effort = effort
    self.enabledAt = enabledAt
    self.modifiedAt = modifiedAt
  }
}

extension CueProfile: Record {
  static let table = Table.cueProfile
  static let columns = ["id", "name", "hostID", "runtime", "model", "effort", "enabledAt", "modifiedAt"]
  var bindings: [any SQLBindable] {
    [Self.recordID, name, hostID, runtime.rawValue, model, effort?.rawValue, enabledAt, modifiedAt]
  }
  init(row: Row) {
    let name = row.text(1).trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      name: name.isEmpty ? Self.defaultName : name, hostID: row.textOrNil(2), runtime: Open(rawValue: row.text(3)),
      model: row.textOrNil(4), effort: row.textOrNil(5).map(Open.init(rawValue:)), enabledAt: row.dateOrNil(6), modifiedAt: row.date(7))
  }
}

public enum CueEnableError: LocalizedError, Equatable {
  /// 那台 Mac 上没有能当大脑的 Agent（参数是各家为什么不能用，`MacAgents.whyNone`）
  case noRuntime(String)
  /// Cue 正在另一台 Mac 上运行（参数是那台的名字，`MacAgents.shownName`），这次没确认要改过来
  case runsElsewhere(String)
  /// 这台的库还没和 iCloud 对过一遍：不知道 Cue 是否已在别的 Mac 上启用（App 层判断，`AppServices.enableCue`）
  case unsynced

  public var errorDescription: String? {
    switch self {
    case .noRuntime(let why): "没有能当 Cue 的 Agent：\(why)"
    case .runsElsewhere(let name): "正在「\(name)」上运行，改过来要先确认"
    case .unsynced: "还没和 iCloud 同步完"
    }
  }
}
