import Foundation

extension CueStore {
  /// 各来源的账号额度；网关的请求能力记录仅在没有账号清单时显示。
  public func accountQuotas() throws -> [AccountQuota] {
    let all = try select(AccountQuota.self, orderBy: "modifiedAt DESC, id")
    let sources = Dictionary(grouping: all, by: { "\($0.hostID)/\($0.account?.source ?? "")" }).mapValues { peers in
      (hasCards: peers.contains { $0.account?.route != nil }, summary: peers.first { $0.account?.route == nil })
    }
    return all.compactMap { quota in
      guard let source = quota.account?.source, let state = sources["\(quota.hostID)/\(source)"] else { return quota }
      if quota.account?.route == nil { return state.hasCards ? nil : quota }
      guard let failure = state.summary, (failure.status == .failed || failure.status == .unsupported), failure.modifiedAt > quota.modifiedAt else { return quota }
      var failed = quota
      failed.status = failure.status
      failed.modifiedAt = failure.modifiedAt
      return failed
    }
  }

  /// 会话共同决定有效来源；尚待桥重新连接的有效记录也保留，避免启动时先连上的会话清掉其他账号。
  /// 一条账号或网关来源的记录，只在每个可能拥有它的模型都证明了别的授权时移除：模型此刻的授权按这次解析的，没解析出就按它最近证明的（`PiModelOption.proven`），
  /// 两样都没有的是未知，保留这个提供方的原生记录与它的网关来源（网关来源归哪个提供方看来源那一条的 `provider`）。
  /// 未解析的那条在这个提供方此刻还有未解析的模型时保留。各来源只看自己的模型，互不影响。
  public func retainQuotaSources(on host: String, models: [PiModelOption]) throws {
    var models = models
    for state in try select(PiSessionState.self, where: "hostID = ? AND \(PiWorkState.outsideSQL(PiWorkState.closed))", [host]) {
      models += [state.model].compactMap { $0 }
      if let id = state.catalogID, let catalog = try agentCatalog(id) { models += catalog.models }
    }
    guard models.contains(where: { ($0.account?.scope ?? $0.proven?.scope) != nil }) else { return }
    try write {
      let quotas = try select(AccountQuota.self, where: "hostID = ?", [host])
      let owners = Dictionary(grouping: quotas.filter { $0.account?.source != nil && $0.account?.route == nil }, by: { $0.account?.source ?? "" })
        .mapValues { Set($0.map(\.provider)) }
      for quota in quotas {
        let valid = models.contains { model in
          guard let fresh = model.account, let account = quota.account else { return false }
          let provider = model.key.provider
          guard account.scope != nil else { return provider == quota.provider && fresh.scope == nil && fresh.kind == account.kind }
          guard let known = fresh.scope != nil ? fresh : model.proven else {
            if let source = account.source { return owners[source]?.contains(provider) == true }
            return provider == quota.provider
          }
          if let source = account.source { return known.source == source }
          return provider == quota.provider && known.source == nil && known.matches(account)
        }
        if !valid { try db.run("DELETE FROM accountQuotas WHERE id = ?", [quota.id]) }
      }
    }
  }

  /// 记下一次观测（只有 Mac 写）。先后只看 `requestedAt`（结果所属操作期间的一个时刻，见 `QuotaReport.requestedAt`）：
  /// 比这条记录已收下的早就丢掉，所以先结束的操作不会盖过后开始的，几个会话进程的结果怎么交错到达都一样。
  /// 只在值有意义地变化时写——状态、窗口、某个窗口的整数百分比、重置时间变了——或上次写已超过 `touchAfter`（只为"更新于"不过时）；
  /// 否则只在本机推进排序时刻、不改版本不同步，每次回复都来的观测不会每次都写库与同步。
  /// 提供方未解析的授权（`scope` 为 nil：还没查，或查时解析失败）是这台 Mac 上这个提供方的一条，不关联任何账号的数值：
  /// 已有证明了身份的账号或来源时不再写"还没查"；同一提供方证明了身份、且不早于它的结果（原生账号或网关来源一级）到来时移除它。返回是否写了。
  @discardableResult
  public func recordQuota(_ report: QuotaReport, host: String) throws -> Bool {
    try write { try applyQuota(report, host: host) }
  }

  private func applyQuota(_ report: QuotaReport, host: String) throws -> Bool {
    let id = AccountQuota.recordID(provider: report.provider, host: host, account: report.account)
    let existing = try find(AccountQuota.self, id)
    if let start = report.requestedAt, let previous = existing?.requestedAt, start < previous { return false }
    var removed = false
    if report.account.route == nil {
      let unresolved = AccountQuota.recordID(provider: report.provider, host: host, account: PiAccount(kind: report.account.kind))
      if report.account.scope == nil {
        if report.status != .failed, try hasProvenPeer(of: report, on: host) { return false }
      } else if let start = report.requestedAt, let pending = try find(AccountQuota.self, unresolved), pending.requestedAt.map({ $0 <= start }) ?? true {
        try db.run("DELETE FROM accountQuotas WHERE id = ?", [unresolved])
        removed = true
      }
    }
    for account in report.accounts ?? [] {
      guard account.account.source == report.account.source, account.account.route != nil else { continue }
      removed = try applyQuota(account, host: host) || removed
    }
    if let scopes = report.activeScopes, let source = report.account.source {
      for old in try select(AccountQuota.self, where: "hostID = ?", [host])
        where old.account?.source == source && old.account?.route != nil && !scopes.contains(old.account?.scope ?? "") {
        try db.run("DELETE FROM accountQuotas WHERE id = ?", [old.id])
        removed = true
      }
    }
    let current = try select(AccountQuota.self, where: "hostID = ?", [host], orderBy: "modifiedAt DESC, id", limit: 1).first
    let now = max(Date.stamp, current?.modifiedAt.addingTimeInterval(AccountQuota.updateStep) ?? .distantPast)
    let status = report.status == .unobserved && !report.complete ? existing?.status ?? .unobserved : report.status
    let details = report.status == .observed ? report.details : existing?.details ?? report.details
    let windows = report.status == .observed ? report.merged(into: existing?.windows ?? []) : existing?.windows ?? []
    let observedAt = report.status == .observed ? report.observedAt ?? now : existing?.observedAt
    if let existing, existing.status == status, existing.account == report.account, existing.details == details, report.activeScopes == nil, !Self.changedMeaningfully(existing.windows, windows),
      now.timeIntervalSince(existing.modifiedAt) < AccountQuota.touchAfter,
      observedAt == existing.observedAt || observedAt?.timeIntervalSince(existing.observedAt ?? .distantPast) ?? 0 < AccountQuota.touchAfter
    {
      if let start = report.requestedAt, start != existing.requestedAt { try db.run("UPDATE accountQuotas SET requestedAt = ? WHERE id = ?", [start, id]) }
      return removed
    }
    let quota = AccountQuota(
      id: id, provider: report.provider, hostID: host, windows: windows, createdAt: existing?.createdAt ?? now, modifiedAt: now,
      account: report.account, status: status, observedAt: observedAt, details: details, requestedAt: report.requestedAt ?? existing?.requestedAt)
    if existing == nil {
      try insert(quota)
    } else {
      try db.run(
        "UPDATE accountQuotas SET windows = ?, modifiedAt = ?, status = ?, observedAt = ?, account = ?, details = ?, requestedAt = ? WHERE id = ?",
        [JSONColumn.encode(windows), now, status.rawValue, observedAt, JSONColumn.encode(report.account), details.map(JSONColumn.encode), quota.requestedAt, id])
    }
    return true
  }

  private func hasProvenPeer(of report: QuotaReport, on host: String) throws -> Bool {
    try select(AccountQuota.self, where: "hostID = ? AND provider = ?", [host, report.provider]).contains {
      $0.account?.route == nil && $0.account?.scope != nil && $0.account?.kind == report.account.kind
    }
  }

  private static func changedMeaningfully(_ old: [QuotaWindow], _ new: [QuotaWindow]) -> Bool {
    guard old.count == new.count else { return true }
    func percent(_ window: QuotaWindow) -> Int { Int((window.used * 100).rounded()) }
    return zip(old, new).contains { old, new in
      old.id != new.id || percent(old) != percent(new) || old.isBinding != new.isBinding
        || abs(old.resetsAt.timeIntervalSince(new.resetsAt)) > AccountQuota.resetTolerance
    }
  }

  /// 请 `host` 那台 Mac 读取额度清单（手机上的额度面板打开时）：与发送共用投送请求与执行器，方式是 `quota`；
  /// 已有一条在路上时返回它，不再写第二条。
  public func requestQuotaRefresh(on host: String) throws -> DeliveryRequest {
    let mode = DeliveryMode.quota
    if let open = try select(DeliveryRequest.self, where: "mode = ? AND status IN (\(DeliveryStatus.openSQL))", [mode.rawValue]).first(where: { $0.hostID == host && Speech.trip($0, at: .always(at: timing.now())).inTransit }) {
      return open
    }
    return try requestDelivery(mode.rawValue, to: SendTarget(kind: .mac, name: "CuePad", ref: nil), on: host, mode: mode)
  }
}
