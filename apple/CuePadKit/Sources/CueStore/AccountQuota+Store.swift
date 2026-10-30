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
  /// 账号或网关来源的记录只按证明移除：可能拥有它的每个模型（同一提供方，或证明过这个来源的）都证明了别的授权，且证明不早于这条记录最近的结果。
  /// 证明只来自在线会话（`PiSession.proofs`，每次解析成功都推进时刻，解析失败不抹掉，含模型范围外、额度查询解析到的）；
  /// 没有证明的模型（还没解析过、或会话不在线只剩存下的模型表）是未知，什么都不移除；旧证明不能否定比它新的记录。
  /// 网关来源归哪些提供方：来源那一条记下的证明过它的提供方（`sourceOwners`，含模型范围外的、会话已退出的），与在线会话证明过它的。各来源只看自己的模型，互不影响。
  /// 未解析的那条在这个提供方此刻还有未解析的模型、且这个提供方没有不早于它的证明时保留。
  public func retainQuotaSources(on host: String, live: [QuotaWitness]) throws {
    var candidates: [QuotaCandidate] = []
    for witness in live {
      for model in witness.models {
        let proof = witness.proofs.first { $0.provider == model.key.provider && $0.id == model.key.id }
        candidates.append(QuotaCandidate(provider: model.key.provider, account: model.account, proof: proof))
      }
      for proof in witness.proofs where !witness.models.contains(where: { $0.key.provider == proof.provider && $0.key.id == proof.id }) {
        candidates.append(QuotaCandidate(provider: proof.provider, account: nil, proof: proof))
      }
    }
    let online = Set(live.map(\.sessionID))
    for state in try select(PiSessionState.self, where: "hostID = ? AND \(PiWorkState.outsideSQL(PiWorkState.closed))", [host]) where !online.contains(state.sessionID) {
      var models = [state.model].compactMap { $0 }
      if let id = state.catalogID, let catalog = try agentCatalog(id) { models += catalog.models }
      candidates += models.map { QuotaCandidate(provider: $0.key.provider, account: $0.account, proof: nil) }
    }
    let proofs = candidates.compactMap(\.proof)
    guard !proofs.isEmpty else { return }
    try write {
      let quotas = try select(AccountQuota.self, where: "hostID = ?", [host])
      var owners: [String: Set<String>] = [:]
      let recorded = try sourceOwners(on: host)
      for quota in quotas where quota.account?.route == nil {
        if let source = quota.account?.source { owners[source, default: []].formUnion([quota.provider] + Array((recorded[quota.id] ?? [:]).keys)) }
      }
      for proof in proofs { if let source = proof.account.source { owners[source, default: []].insert(proof.provider) } }
      for quota in quotas {
        guard let account = quota.account else { try db.run("DELETE FROM accountQuotas WHERE id = ?", [quota.id]); continue }
        let mine = candidates.filter { candidate in
          if let source = account.source { return owners[source]?.contains(candidate.provider) == true }
          return candidate.provider == quota.provider
        }
        let valid = mine.contains { candidate in
          guard account.scope != nil else {
            return candidate.account?.scope == nil && candidate.account?.kind == account.kind && !Self.proves(proofs, quota.provider, account.kind, since: quota.evidencedAt)
          }
          guard let proof = candidate.proof else { return true }
          if let source = account.source { return proof.account.source == source || proof.at < quota.evidencedAt }
          return proof.account.source == nil && proof.account.matches(account) || proof.at < quota.evidencedAt
        }
        if !valid { try db.run("DELETE FROM accountQuotas WHERE id = ?", [quota.id]) }
      }
    }
  }

  /// 记下一次观测（只有 Mac 写）。先后只看 `requestedAt`（结果所属操作期间的一个时刻，见 `QuotaReport.requestedAt`）：
  /// 比这条记录已收下的早就丢掉，所以先结束的操作不会盖过后开始的，几个会话进程的结果怎么交错到达都一样。
  /// 只在值有意义地变化时写——状态、窗口、某个窗口的整数百分比、重置时间变了——或上次写已超过 `touchAfter`（只为"更新于"不过时）；
  /// 否则只在本机推进排序时刻、不改版本不同步，每次回复都来的观测不会每次都写库与同步。
  /// 提供方未解析的授权（`scope` 为 nil：还没查，或查时解析失败）是这台 Mac 上这个提供方的一条，不关联任何账号的数值，与证明了身份的结果按同一个时刻排先后：
  /// 已有证明了身份的账号或来源时不再写"还没查"；查时解析失败只在这个提供方没有不早于它的证明时写；同一提供方证明了身份、且不早于它的结果到来时移除它。
  /// 证明既看额度记录（网关来源那一条记下的每个提供方与时刻，`owners`），也看在线会话的证明（`proofs`，同 `retainQuotaSources`），
  /// 写入与保留核对用同一个判断，到达先后不影响结果。网关来源一级的报告带来的提供方与时刻只并进那一条（取较晚的，不删），较早的报告被丢掉时也并：
  /// 那次解析是真的证明；并进时移除这些提供方不晚于它的未解析那条。
  /// 网关清单里各账号的报告用清单的排序时刻。返回是否写了。
  @discardableResult
  public func recordQuota(_ report: QuotaReport, host: String, proofs: [PiProof] = []) throws -> Bool {
    try write { try applyQuota(report, host: host, proofs: proofs) }
  }

  private func applyQuota(_ report: QuotaReport, host: String, proofs: [PiProof]) throws -> Bool {
    let wrote = try applyReport(report, host: host, proofs: proofs)
    guard let owners = report.owners, report.account.source != nil, report.account.route == nil else { return wrote }
    return try mergeOwners(owners, into: AccountQuota.recordID(provider: report.provider, host: host, account: report.account), kind: report.account.kind, host: host) || wrote
  }

  private func applyReport(_ report: QuotaReport, host: String, proofs: [PiProof]) throws -> Bool {
    let id = AccountQuota.recordID(provider: report.provider, host: host, account: report.account)
    let existing = try find(AccountQuota.self, id)
    if let start = report.requestedAt, let previous = existing?.requestedAt, start < previous { return false }
    var removed = false
    if report.account.route == nil {
      let unresolved = AccountQuota.recordID(provider: report.provider, host: host, account: PiAccount(kind: report.account.kind))
      if report.account.scope == nil {
        let since = report.status == .failed ? report.requestedAt : nil
        if try hasProvenPeer(of: report, on: host, since: since) || Self.proves(proofs, report.provider, report.account.kind, since: since ?? .distantPast) { return false }
      } else if let start = report.requestedAt, let pending = try find(AccountQuota.self, unresolved), pending.requestedAt.map({ $0 <= start }) ?? true {
        try db.run("DELETE FROM accountQuotas WHERE id = ?", [unresolved])
        removed = true
      }
    }
    for var account in report.accounts ?? [] {
      guard account.account.source == report.account.source, account.account.route != nil else { continue }
      account.requestedAt = report.requestedAt
      removed = try applyQuota(account, host: host, proofs: proofs) || removed
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

  /// 这个 Pi 提供方有没有不早于 `since` 的证明：不经额度记录上记着的提供方名（几个提供方共用一个网关来源时那里只有一个）。
  private static func proves(_ proofs: [PiProof], _ provider: String, _ kind: PiAccount.Kind, since: Date) -> Bool {
    proofs.contains { $0.provider == provider && $0.account.kind == kind && $0.at >= since }
  }

  /// 这个提供方有没有证明了身份的结果：它自己写的原生账号或来源那一条，或记下它证明过的网关来源；给了 `since` 时只算不早于它的。
  private func hasProvenPeer(of report: QuotaReport, on host: String, since start: Date?) throws -> Bool {
    let owners = try sourceOwners(on: host)
    return try select(AccountQuota.self, where: "hostID = ?", [host]).contains { peer in
      guard peer.account?.route == nil, peer.account?.scope != nil, peer.account?.kind == report.account.kind else { return false }
      if let at = owners[peer.id]?[report.provider], start.map({ at >= $0 }) ?? true { return true }
      guard peer.provider == report.provider else { return false }
      guard let start else { return true }
      return peer.requestedAt.map { $0 >= start } ?? false
    }
  }

  /// 网关来源那一条记下的证明过它的 Pi 提供方与各自最近的时刻（本机列 `owners`，不同步）。
  private func sourceOwners(on host: String) throws -> [UUID: [String: Date]] {
    let rows = try db.query("SELECT id, owners FROM accountQuotas WHERE hostID = ? AND owners IS NOT NULL", [host]) { ($0.uuid(0), $0.text(1)) }
    return Dictionary(rows.map { ($0.0, Self.decodeOwners($0.1)) }, uniquingKeysWith: { $1 })
  }

  /// 把这些提供方与时刻并进来源那一条（取较晚的，不删），并移除它们不晚于这次证明的未解析那条。返回是否移除了记录。
  private func mergeOwners(_ owners: [String: Date], into id: UUID, kind: PiAccount.Kind, host: String) throws -> Bool {
    guard !owners.isEmpty, let text = try db.first("SELECT owners FROM accountQuotas WHERE id = ?", [id], { $0.textOrNil(0) }) else { return false }
    let merged = (text.map(Self.decodeOwners) ?? [:]).merging(owners, uniquingKeysWith: max)
    try db.run("UPDATE accountQuotas SET owners = ? WHERE id = ?", [Self.encodeOwners(merged), id])
    var removed = false
    for (provider, at) in owners {
      let unresolved = AccountQuota.recordID(provider: provider, host: host, account: PiAccount(kind: kind))
      guard let pending = try find(AccountQuota.self, unresolved), pending.requestedAt.map({ $0 <= at }) ?? true else { continue }
      try db.run("DELETE FROM accountQuotas WHERE id = ?", [unresolved])
      removed = true
    }
    return removed
  }

  private static func decodeOwners(_ text: String) -> [String: Date] {
    ((try? JSONDecoder().decode([String: Double].self, from: Data(text.utf8))) ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
  }

  private static func encodeOwners(_ owners: [String: Date]) -> String {
    String(decoding: (try? JSONEncoder().encode(owners.mapValues(\.timeIntervalSince1970))) ?? Data("{}".utf8), as: UTF8.self)
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

/// 一个在线会话交给额度保留核对的事实：它的模型表与它证明过的授权。
public struct QuotaWitness: Sendable {
  public var sessionID: String
  public var models: [PiModelOption]
  public var proofs: [PiProof]

  public init(sessionID: String, models: [PiModelOption], proofs: [PiProof]) {
    self.sessionID = sessionID
    self.models = models
    self.proofs = proofs
  }
}

/// 可能拥有某条额度记录的一个模型：这一次解析出的授权，与它最近的证明（没有是未知）。
private struct QuotaCandidate {
  let provider: String
  let account: PiAccount?
  let proof: PiProof?
}
