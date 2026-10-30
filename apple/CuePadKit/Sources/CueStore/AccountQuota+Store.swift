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
      if quota.status == .unsupported { return quota }
      guard let failure = state.summary, failure.status == .failed, failure.modifiedAt > quota.modifiedAt else { return quota }
      var failed = quota
      failed.status = .failed
      failed.modifiedAt = failure.modifiedAt
      return failed
    }
  }

  /// 会话共同决定有效来源；尚待桥重新连接的有效记录也保留，避免启动时先连上的会话清掉其他账号。
  public func retainQuotaSources(on host: String, models: [PiModelOption]) throws {
    var models = models
    for state in try select(PiSessionState.self, where: "hostID = ? AND \(PiWorkState.outsideSQL(PiWorkState.closed))", [host]) {
      models += [state.model].compactMap { $0 }
      if let id = state.catalogID, let catalog = try agentCatalog(id) { models += catalog.models }
    }
    guard models.contains(where: { $0.account?.scope != nil }) else { return }
    try write {
      for quota in try select(AccountQuota.self, where: "hostID = ?", [host]) {
        let valid = models.contains { model in
          guard let account = model.account else { return false }
          if let source = quota.account?.source { return account.source == source }
          return model.key.provider == quota.provider && account.source == nil && (account.scope == nil || account.matches(quota.account))
        }
        if !valid { try db.run("DELETE FROM accountQuotas WHERE id = ?", [quota.id]) }
      }
    }
  }

  /// 记下一次观测（只有 Mac 写）。只在值有意义地变化时写——窗口变了、某个窗口的整数百分比变了、重置时间变了——
  /// 或上次写已超过 `touchAfter`（只为"更新于"不过时）；否则不写，每次回复都来的观测不会每次都写库与同步。返回是否写了。
  @discardableResult
  public func recordQuota(_ report: QuotaReport, host: String) throws -> Bool {
    try write {
      var removed = false
      if let scopes = report.activeScopes, let source = report.account.source {
        for old in try select(AccountQuota.self, where: "hostID = ?", [host])
          where old.account?.source == source && old.account?.route != nil && !scopes.contains(old.account?.scope ?? "") {
          try db.run("DELETE FROM accountQuotas WHERE id = ?", [old.id])
          removed = true
        }
      }
      let id = AccountQuota.recordID(provider: report.provider, host: host, account: report.account)
      let existing = try find(AccountQuota.self, id)
      let current = try select(AccountQuota.self, where: "hostID = ?", [host], orderBy: "modifiedAt DESC, id", limit: 1).first
      let now = max(Date.stamp, current?.modifiedAt.addingTimeInterval(AccountQuota.updateStep) ?? .distantPast)
      if report.status == .observed, let stamp = report.observedAt, let previous = existing?.observedAt, stamp < previous { return removed }
      let status = report.status == .unobserved && !report.complete ? existing?.status ?? .unobserved : report.status
      let windows = report.status == .observed ? report.merged(into: existing?.windows ?? []) : existing?.windows ?? []
      let observedAt = report.status == .observed ? report.observedAt ?? now : existing?.observedAt
      if let existing, existing.status == status, existing.account == report.account, !Self.changedMeaningfully(existing.windows, windows),
        now.timeIntervalSince(existing.modifiedAt) < AccountQuota.touchAfter,
        observedAt == existing.observedAt || observedAt?.timeIntervalSince(existing.observedAt ?? .distantPast) ?? 0 < AccountQuota.touchAfter
      {
        return removed
      }
      let quota = AccountQuota(
        id: id, provider: report.provider, hostID: host, windows: windows, createdAt: existing?.createdAt ?? now, modifiedAt: now,
        account: report.account, status: status, observedAt: observedAt)
      if existing == nil {
        try insert(quota)
      } else {
        try db.run(
          "UPDATE accountQuotas SET windows = ?, modifiedAt = ?, status = ?, observedAt = ?, account = ? WHERE id = ?",
          [JSONColumn.encode(windows), now, status.rawValue, observedAt, JSONColumn.encode(report.account), id])
      }
      return true
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

  /// 请 `host` 那台 Mac 刷新订阅额度（手机上的额度视图打开、数据陈旧时）：与发送共用投送请求与执行器，方式是 `quota`；
  /// 已有一条在路上时返回它，不再写第二条。
  public func requestQuotaRefresh(on host: String) throws -> DeliveryRequest {
    let mode = DeliveryMode.quota
    if let open = try select(DeliveryRequest.self, where: "mode = ? AND status IN (\(DeliveryStatus.openSQL))", [mode.rawValue]).first {
      return open
    }
    return try requestDelivery(mode.rawValue, to: SendTarget(kind: .mac, name: "CuePad", ref: nil), on: host, mode: mode)
  }
}
