import Foundation

extension CueStore {
  public func cueProfile() throws -> CueProfile? { try find(CueProfile.self, CueProfile.recordID) }

  /// 读、改、写在同一个事务里，`edit` 可按读到的最新值决定改不改；什么都没改就不写。
  @discardableResult
  public func updateCueProfile(_ edit: @Sendable (inout CueProfile) -> Void) throws -> CueProfile {
    try write { try editProfile(edit) }
  }

  /// 手机与 Mac 同一条规则，按那台写下的能用的 Agent（`MacAgents`）判断：选的 Agent 那台用不了才换成第一家能用的，模型属于原来那家、一并清掉；强度留着。那台一家都不能用时抛 `CueEnableError`。Cue 正在另一台上运行时只有 `moving`（你确认了要改过来）才改，否则抛 `CueEnableError.runsElsewhere`：同一个事务里读、判、写，读到别的设备刚同步来的启用也不会悄悄把它抢过来。
  public func enableCue(on host: String, moving: Bool) throws {
    try write {
      if let running = try cueProfile()?.activeHost, running != host, !moving {
        throw CueEnableError.runsElsewhere(try macAgents(on: running).shownName)
      }
      let usable = try macAgents(on: host)
      let available = AgentKind.allCases.filter(usable.kinds.contains)
      guard let first = available.first else { throw CueEnableError.noRuntime(usable.whyNone) }
      _ = try editProfile { profile in
        profile.hostID = host
        profile.enabledAt = .now
        if profile.runtime.known.map(available.contains) != true {
          profile.runtime = .known(first)
          profile.model = nil
          profile.fast = false
        }
      }
    }
  }

  /// 必须在写事务内调用。
  func editProfile(_ edit: (inout CueProfile) -> Void) throws -> CueProfile {
    let stored = try cueProfile()
    var profile = stored ?? CueProfile()
    edit(&profile)
    if let stored, profile == stored { return stored }
    profile.modifiedAt = Date.stamp
    try upsert(profile)
    return profile
  }

  public func cueState() throws -> CueState? { try find(CueState.self, CueState.recordID).map { try runtimeProjection($0) } }

  /// 那台 Mac 的期限到了由订阅重读（`macOnline`），“等你 N”、会话显示与手机推送标志到点自己变。
  public func cueDuty() throws -> CueDuty? {
    guard let profile = try cueProfile(), let host = profile.activeHost else { return nil }
    let state = try cueState()
    guard profile.onDuty(state, hostOnline: try macOnline(host)) else { return nil }
    return CueDuty(name: profile.name, left: state?.left ?? [])
  }

  /// 会话没停着（在跑、已结束）抛 `notStopped`。你发起的一轮停下不经这里，当场留给你（`leaveHisStops`）。
  @discardableResult
  public func leaveToYou(_ sessionID: String) throws -> UUID {
    try write {
      guard let session = try sessionState(sessionID) else { throw CueStoreError.notFound }
      guard session.state.known?.isStopped == true else { throw CueStoreError.notStopped(session.title) }
      try putLeft([session])
      return CueState.recordID
    }
  }

  /// 会话仍停在 `stop` 那次停下、等你里没有问着他的提问，且它与它绑着的任务（含上级）都不在 `given` 里，它的去处就是留给你回：已经留着的（他发起的那一轮停下时当场留了）不再写。不用留为 nil。
  public func leaveUnattended(_ stop: CueLeft, given: Set<UUID>) throws -> SessionState? {
    try write {
      guard let session = try sessionState(stop.sessionID), stop.holds(for: session), try question(waitingOn: session.sessionID) == nil else { return nil }
      guard !given.contains(session.id), given.isDisjoint(with: try sessionPlaces(session.sessionID)) else { return nil }
      if try cueState()?.left.contains(where: { $0.holds(for: session) }) != true { try putLeft([session]) }
      return session
    }
  }

  /// 没留给你的返回 false。
  public func takeBack(_ sessionID: String) throws -> Bool {
    try write {
      guard let session = try sessionState(sessionID), try cueState()?.left.contains(where: { $0.holds(for: session) }) == true else { return false }
      try putLeft([], removing: sessionID)
      return true
    }
  }

  /// 去掉 `removing` 与已作废的，表里只留此刻还成立的；和库里一样就不写。必须在写事务内调用。
  @discardableResult
  func putLeft(_ sessions: [SessionState], removing: String? = nil) throws -> Bool {
    let current = try cueState()
    let replaced = Set(sessions.map(\.sessionID) + [removing].compactMap(\.self))
    let others = current?.left.filter { !replaced.contains($0.sessionID) } ?? []
    let live = try select(SessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(others.map(\.sessionID))])
    let left = others.filter { entry in live.contains(where: entry.holds) } + sessions.map { CueLeft(sessionID: $0.sessionID, since: $0.stateSince) }
    guard Set(left) != Set(current?.left ?? []) else { return false }
    let next = CueState(
      state: current?.state ?? .known(.settled), detail: current?.detail, step: current?.step, round: current?.round, context: current?.context,
      left: left, modifiedAt: Date.stamp)
    try upsert(next, updating: ["leftToYou", "modifiedAt"])
    return true
  }

  public func cueWaking() throws -> CueMessage? {
    guard let round = try cueState()?.round, let row = try find(CueMessage.self, round), row.wake != nil else { return nil }
    return row
  }

  /// 不在值班写歇着、没有上下文。只有真实报告提供宿主与 boot；缺少身份的写入保留原报告，但不签发当前运行证明。
  public func setCueState(
    _ state: WorkState, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil,
    hostID: String? = nil, bootID: String? = nil
  ) throws {
    try write { try putCueState(state, detail: detail, step: step, round: round, context: context, hostID: hostID, bootID: bootID) }
  }

  func putCueState(
    _ state: WorkState, detail: String?, step: CueActivity.Touch?, round: UUID?, context: CueContext?, hostID: String?, bootID: String?
  ) throws {
    let current = try cueState()
    let next = CueState(
      state: .known(state), detail: detail, step: step, round: round, context: context, left: current?.left ?? [], modifiedAt: Date.stamp, hostID: hostID, bootID: bootID)
    if let current, (current.state, current.detail, current.step, current.round, current.context) == (next.state, next.detail, next.step, next.round, next.context),
      current.hostID == next.hostID, current.bootID == next.bootID {
      return
    }
    try upsert(next, updating: ["state", "detail", "step", "modifiedAt", "round", "context", "hostID", "bootID"])
  }
}
