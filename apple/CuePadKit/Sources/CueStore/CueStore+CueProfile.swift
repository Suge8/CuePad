import Foundation

extension CueStore {
  /// Cue 的设置；从没设过为 nil。
  public func cueProfile() throws -> CueProfile? { try find(CueProfile.self, CueProfile.recordID) }

  /// 改设置（没有就从默认值建一行）；返回改后的。读、改、写在同一个事务里，`edit` 可按读到的最新值决定改不改；什么都没改就不写。
  @discardableResult
  public func updateCueProfile(_ edit: @Sendable (inout CueProfile) -> Void) throws -> CueProfile {
    try write { try editProfile(edit) }
  }

  /// 让 Cue 运行在 `host` 那台 Mac 并启用（另一台上的会停下）——手机与 Mac 同一条规则，按那台写下的能用的 Agent（`MacAgents`）判断：
  /// 选的 Agent 那台用不了才换成第一家能用的（按 `AgentKind` 的顺序），模型属于原来那家、一并清掉；强度留着（运行时自己取档）。
  /// 那台一家都不能用时抛 `CueEnableError`，带上各家为什么。Cue 正在另一台上运行时只有 `moving`（你确认了要改过来）才改，否则抛
  /// `CueEnableError.runsElsewhere`：同一个事务里读、判、写，读到别的设备刚同步来的启用也不会悄悄把它抢过来。
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
        }
      }
    }
  }

  /// `updateCueProfile` 的事务内部分：必须在写事务内调用。
  func editProfile(_ edit: (inout CueProfile) -> Void) throws -> CueProfile {
    let stored = try cueProfile()
    var profile = stored ?? CueProfile()
    edit(&profile)
    if let stored, profile == stored { return stored }
    profile.modifiedAt = Date.stamp
    try upsert(profile)
    return profile
  }

  /// Cue 此刻在做什么；值班的 Mac 还没写过为 nil。
  public func cueState() throws -> CueState? { try find(CueState.self, CueState.recordID) }

  /// Cue 在值班时的那一份（`CueDuty`：名字与留给你回的会话）；不在值班为 nil。值班按 `CueProfile.onDuty`（各端读同步来的设置、状态与它那台 Mac 的在线记录），
  /// 那台 Mac 的期限到了由订阅重读（`macOnline`），"等你 N"、会话显示与手机推送标志到点自己变。
  public func cueDuty() throws -> CueDuty? {
    guard let profile = try cueProfile(), let host = profile.activeHost else { return nil }
    let state = try cueState()
    guard profile.onDuty(state, hostOnline: try macOnline(host)) else { return nil }
    return CueDuty(name: profile.name, left: state?.left ?? [])
  }

  /// Cue 把会话此刻的这次停下留给你回（`CueLeft`）：会话行显示"待回复"（在等回答的回到等你确认），谁再对它说话就作废。
  /// 会话没停着（在跑、出错、已结束）抛 `notStopped`。顺手去掉已作废的旧条目，表里只留此刻还成立的。返回记录 id（立即上传用）。
  @discardableResult
  public func leaveToYou(_ sessionID: String) throws -> UUID {
    try write {
      guard let session = try sessionState(sessionID) else { throw CueStoreError.notFound }
      guard session.state.known?.isStopped == true else { throw CueStoreError.notStopped(session.title) }
      let current = try cueState()
      let others = current?.left.filter { $0.sessionID != sessionID } ?? []
      let sessions = try select(
        PiSessionState.self, where: "sessionID IN (SELECT value FROM json_each(?))", [JSONColumn.encode(others.map(\.sessionID))])
      let left = others.filter { entry in sessions.contains(where: entry.holds) } + [CueLeft(sessionID: sessionID, since: session.stateSince)]
      let next = CueState(
        state: current?.state ?? .known(.settled), detail: current?.detail, step: current?.step, round: current?.round, context: current?.context,
        left: left, modifiedAt: Date.stamp)
      try upsert(next, updating: ["leftToYou", "modifiedAt"])
      return CueState.recordID
    }
  }

  /// Cue 在跑的这一轮自己醒来的那一行（经过那一行，带着为什么醒 `CueMessage.wake`、几点醒的与叫醒它的那几处当时叫什么）；
  /// 歇着、这一轮还没有那一行、不是自己醒来的为 nil。各端画叫醒的那一下只读它。
  public func cueWaking() throws -> CueMessage? {
    guard let round = try cueState()?.round, let row = try find(CueMessage.self, round), row.wake != nil else { return nil }
    return row
  }

  /// 值班的 Mac 写下 Cue 此刻的样子（在做什么、这个班次的上下文），整行一次写；和库里一样就不写（不触发同步）。不在值班写歇着、没有上下文。
  public func setCueState(
    _ state: PiWorkState, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil
  ) throws {
    try write { try putCueState(state, detail: detail, step: step, round: round, context: context) }
  }

  func putCueState(_ state: PiWorkState, detail: String?, step: CueActivity.Touch?, round: UUID?, context: CueContext?) throws {
    let current = try cueState()
    let next = CueState(
      state: .known(state), detail: detail, step: step, round: round, context: context, left: current?.left ?? [], modifiedAt: Date.stamp)
    if let current, (current.state, current.detail, current.step, current.round, current.context) == (next.state, next.detail, next.step, next.round, next.context) {
      return
    }
    try upsert(next, updating: ["state", "detail", "step", "modifiedAt", "round", "context"])
  }
}
