import Foundation

/// 订阅账号的一个用量窗口（Pi 用的 OAuth 订阅：Claude、Codex；按量计费的 API 密钥没有）。
/// 一个账号有几个窗口：Claude 是 5 小时、本周与按模型的周额度，Codex 按套餐有一到两个。
public struct QuotaWindow: Sendable, Equatable, Codable, Identifiable {
  /// 窗口长度（秒）
  public var seconds: Int
  public static let week = 7 * 86_400
  /// 这个窗口已用的比例，0 到 1（到顶后提供方可能报得略超 1）
  public var used: Double
  public var resetsAt: Date
  /// 只算某个模型的窗口（Claude 按模型的周额度，提供方给的显示名，如 "Fable"）；算整个账号的为 nil
  public var model: String?
  /// 提供方说此刻卡着的就是这个窗口（Claude 响应头的 representative-claim）；提供方没说的（用量接口、Codex）为 false
  public var isBinding: Bool

  /// 报不出有限值的已用比例（NaN、无穷）按 0 记：界面按它换算百分比与弧长，非有限值在整数转换处会崩溃。
  public init(seconds: Int, used: Double, resetsAt: Date, model: String? = nil, isBinding: Bool = false) {
    self.seconds = seconds
    self.used = used.isFinite ? used : 0
    self.resetsAt = resetsAt
    self.model = model
    self.isBinding = isBinding
  }

  private enum CodingKeys: String, CodingKey {
    case seconds, used, resetsAt, model
    case isBinding = "binding"
  }

  /// 线上与存储里 `binding` 只在为真时出现。
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seconds: c.decode(Int.self, forKey: .seconds), used: c.decode(Double.self, forKey: .used), resetsAt: c.decode(Date.self, forKey: .resetsAt),
      model: c.decodeIfPresent(String.self, forKey: .model), isBinding: c.decodeIfPresent(Bool.self, forKey: .isBinding) ?? false)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(seconds, forKey: .seconds)
    try c.encode(used, forKey: .used)
    try c.encode(resetsAt, forKey: .resetsAt)
    try c.encodeIfPresent(model, forKey: .model)
    if isBinding { try c.encode(true, forKey: .isBinding) }
  }

  /// 哪一个窗口：长度与模型（名字是给人看的，不同长度可能写成同一个"N 小时"）。同一个窗口的几次观测按它并成一条。
  public struct Slot: Hashable, Sendable {
    public let seconds: Int
    public let model: String?
  }
  public var id: Slot { Slot(seconds: seconds, model: model) }

  /// 最近观测的比例；重置不代表已观测到恢复。
  public func used(at now: Date) -> Double { min(max(used, 0), 1) }

  /// 匀速刻度：窗口已过去的时间占多少，即按匀速此刻该用到多少（0 到 1）；过了重置时间是 0。
  public func pace(at now: Date) -> Double {
    guard now < resetsAt, seconds > 0 else { return 0 }
    return min(max(1 - resetsAt.timeIntervalSince(now) / Double(seconds), 0), 1)
  }

  /// 照这个窗口里到此刻的速度，什么时候用完；没超过匀速刻度（重置前用不完）、已经到顶或已重置为 nil。
  /// 超过刻度时，用完一定早于重置（已用 > 已过的时间比例，剩下的按同一速度用得比时间走得快）。
  public func exhaustion(at now: Date) -> Date? {
    let used = used(at: now), pace = pace(at: now)
    guard used < 1, pace > 0, used > pace else { return nil }
    let elapsed = pace * Double(seconds)
    return now.addingTimeInterval((1 - used) * elapsed / used)
  }
}

/// 一个账号最近一次观测到的用量（同步表 `accountQuotas`，Mac 写、各端读）：每台 Mac 的每个授权分区一条，不跨账号、来源合并。
/// 观测来自 Pi 会话里的扩展；读取网关清单只发现账号，不保证提供方的原观测已更新。
/// "更新于"读 `observedAt`；`modifiedAt` 表示能力、结果或当前授权发生变化。
public struct AccountQuota: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 原生提供方 id，或网关完整上游 provider（可含远端前缀）
  public var provider: String
  /// 写下这次观测的 Mac：手机请 Mac 刷新时发给它
  public var hostID: String
  /// 读取时关联 MacAgents 的名字，不随额度另存。
  public var macName: String
  public var account: PiAccount?
  public var status: QuotaStatus
  public var observedAt: Date?
  /// 已收下的最晚排序时刻（`QuotaReport.requestedAt`），只用于拒绝晚到的结果，不代替原观测时间。
  public var requestedAt: Date?
  /// 按窗口从短到长（同长的整个账号在前，按模型的在后）
  public var windows: [QuotaWindow]
  public var details: QuotaDetails?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 原观测超过这么久标为陈旧；它不决定账号清单是否需要读取。
  public static let staleAfter: TimeInterval = 10 * 60
  /// 用量没有有意义的变化时，观测时间最多拖这么久才写一次（只为"更新于"不过时）；有变化随时写。
  static let touchAfter: TimeInterval = staleAfter / 2
  /// 重置时间相差不超过这么多算同一个（同一窗口里提供方报的重置时刻会差几百毫秒）。
  static let resetTolerance: TimeInterval = 60
  /// 同一毫秒切换授权也要有确定的先后；数据库与同步的时刻精度是毫秒。
  static let updateStep: TimeInterval = 0.001

  public init(id: UUID, provider: String, hostID: String, windows: [QuotaWindow], createdAt: Date, modifiedAt: Date,
    account: PiAccount? = nil, status: QuotaStatus = .observed, observedAt: Date? = nil, details: QuotaDetails? = nil, requestedAt: Date? = nil, macName: String = MacAgents.unnamed) {
    self.id = id
    self.provider = provider
    self.hostID = hostID
    self.macName = macName
    self.account = account
    self.status = status
    self.observedAt = observedAt
    self.requestedAt = requestedAt
    self.windows = windows
    self.details = details
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
  }

  public func isStale(at now: Date) -> Bool {
    switch status {
    case .unsupported: false
    case .unobserved: true
    case .failed: true
    case .observed: now.timeIntervalSince(observedAt ?? modifiedAt) >= Self.staleAfter || windows.contains { now >= $0.resetsAt }
    }
  }

  public enum Reading: Sendable, Equatable { case observed, unobserved, unsupported, failed, expired }

  public func reading(at now: Date) -> Reading {
    if status == .unsupported { return .unsupported }
    guard account?.scope != nil else { return status == .failed ? .failed : .unobserved }
    switch status {
    case .unsupported: return .unsupported
    case .failed: return .failed
    case .unobserved: return .unobserved
    case .observed:
      guard !windows.isEmpty || details?.hasReading == true else { return .unobserved }
      return windows.contains { now >= $0.resetsAt } || details?.values.contains { $0.resetsAt.map { now >= $0 } == true } == true ? .expired : .observed
    }
  }

  /// 卡着的窗口：提供方说了是哪个（`QuotaWindow.isBinding`，Claude）且还没过重置时间就是它；没说（Codex、用量接口刚替换过）
  /// 或它已重置时，是此刻用得最多的那个。`model` 给了时按模型的周额度也参与比较（只算名字出现在模型 id 或名字里的，如 Fable 之于 claude-fable-5）。
  public func binding(at now: Date, model: String? = nil) -> QuotaWindow? {
    guard reading(at: now) == .observed else { return nil }
    if let claimed = windows.first(where: { $0.isBinding && now < $0.resetsAt }) { return claimed }
    let model = model?.lowercased()
    return windows.filter { window in
      guard let scope = window.model?.lowercased() else { return true }
      return model?.contains(scope) == true
    }.max { $0.used(at: now) < $1.used(at: now) }
  }

  static func recordID(provider: String, host: String, account: PiAccount?) -> UUID {
    DeterministicID.uuid("account-quota/\(host)/\(provider)/\(account?.kind.rawValue ?? "unknown")/\(account?.scope ?? "unknown")")
  }
}

/// 扩展报来的一次观测（桥协议的 `quota` 消息，线上格式即此）。
public struct QuotaReport: Sendable, Equatable, Decodable {
  public var provider: String
  public var account: PiAccount
  public var status: QuotaStatus
  public var windows: [QuotaWindow]
  /// 是这个账号的全部窗口（查用量接口得到的）：替换已存的；回复里带回的只有一部分（Claude 的响应头没有按模型的周额度），按窗口并进已存的
  public var complete: Bool
  /// 网关的原始 readAt（Unix 秒）；不以取缓存的时刻替换。
  public var observedAt: Date?
  /// 同一网关成功返回的账号清单；仅用于移除该来源已撤销的账号。
  public var activeScopes: [String]?
  public var accounts: [QuotaReport]?
  /// 排序时刻：这份结果所属操作期间的一个时刻——主动查询（成功、失败、不支持、网关清单）取请求开始，回复带回的观测取收到回复。
  /// 取在操作期间以内，先结束的操作的时刻一定早于后开始的；能力声明不带。
  public var requestedAt: Date?
  public var details: QuotaDetails?

  public init(provider: String, windows: [QuotaWindow], complete: Bool, account: PiAccount, status: QuotaStatus = .observed, observedAt: Date? = nil, activeScopes: [String]? = nil, details: QuotaDetails? = nil, accounts: [QuotaReport]? = nil, requestedAt: Date? = nil) {
    self.provider = provider
    self.account = account
    self.status = status
    self.windows = windows
    self.complete = complete
    self.observedAt = observedAt
    self.requestedAt = requestedAt
    self.accounts = accounts
    self.activeScopes = activeScopes
    self.details = details
  }

  /// 并进已存的窗口，排成 `AccountQuota.windows` 的顺序。这次观测没说哪个卡着（用量接口、Codex）时，沿用已存的那个说法：
  /// 提供方的判定只来自 Claude 的响应头，下一次回复会更新它。
  /// 同一个窗口报了几次的只留第一次：存下的窗口一个窗口一条（界面按窗口认总览的行）。
  func merged(into stored: [QuotaWindow]) -> [QuotaWindow] {
    var reported: [QuotaWindow] = []
    for window in windows where !reported.contains(where: { $0.id == window.id }) { reported.append(window) }
    if !reported.contains(where: \.isBinding), let claimed = stored.first(where: \.isBinding),
      let index = reported.firstIndex(where: { $0.id == claimed.id })
    {
      reported[index].isBinding = true
    }
    let kept = complete ? [] : stored.filter { old in !reported.contains { $0.id == old.id } }
    return (reported + kept).sorted(by: Self.order)
  }

  /// 短的在前；同长的整个账号在前、按模型的按名字在后。
  private static func order(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
    if a.seconds != b.seconds { return a.seconds < b.seconds }
    switch (a.model, b.model) {
    case (nil, nil), (.some, nil): return false
    case (nil, .some): return true
    case (.some(let x), .some(let y)): return x < y
    }
  }
}

extension AccountQuota: Record {
  static let table = Table.accountQuotas
  static let columns = ["id", "provider", "hostID", "windows", "createdAt", "modifiedAt", "account", "status", "observedAt", "details", "requestedAt"]
  static var selection: String { (columns + [MacAgents.nameSQL(host: "accountQuotas.hostID")]).joined(separator: ", ") }
  var bindings: [any SQLBindable] { [id, provider, hostID, JSONColumn.encode(windows), createdAt, modifiedAt, account.map(JSONColumn.encode), status.rawValue, observedAt, details.map(JSONColumn.encode), requestedAt] }
  init(row: Row) {
    self.init(
      id: row.uuid(0), provider: row.text(1), hostID: row.text(2), windows: JSONColumn.decodeList(QuotaWindow.self, from: row.text(3)),
      createdAt: row.date(4), modifiedAt: row.date(5), account: JSONColumn.decode(PiAccount.self, from: row.textOrNil(6)),
      status: row.textOrNil(7).flatMap(QuotaStatus.init(rawValue:)) ?? .unobserved, observedAt: row.dateOrNil(8), details: JSONColumn.decode(QuotaDetails.self, from: row.textOrNil(9)), requestedAt: row.dateOrNil(10), macName: MacAgents.shownName(row.textOrNil(11)))
  }
}
