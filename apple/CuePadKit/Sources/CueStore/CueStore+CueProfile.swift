import Foundation

extension CueStore {
  public func cueProfile() throws -> CueProfile? { try find(CueProfile.self, CueProfile.recordID) }

  @discardableResult
  public func updateCueProfile(_ edit: @Sendable (inout CueProfile) -> Void) throws -> CueProfile {
    try write { try editProfile(edit) }
  }

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

  public func cueDuty() throws -> CueDuty? {
    guard let profile = try cueProfile(), let host = profile.activeHost else { return nil }
    let state = try cueState()
    guard profile.onDuty(state, hostOnline: try macOnline(host)) else { return nil }
    return CueDuty(name: profile.name, left: state?.left ?? [], tiers: try chosenTiers())
  }

  @discardableResult
  public func leaveToYou(_ sessionID: String) throws -> UUID {
    try write {
      guard let session = try sessionState(sessionID) else { throw CueStoreError.notFound }
      guard session.state.known?.isStopped == true else { throw CueStoreError.notStopped(session.title) }
      try putLeft([session])
      return CueState.recordID
    }
  }

  public func leaveUnattended(_ stop: CueLeft, given: Set<UUID>) throws -> SessionState? {
    try write {
      guard let session = try sessionState(stop.sessionID), stop.holds(for: session) else { return nil }
      guard !given.contains(session.id), given.isDisjoint(with: try sessionPlaces(session.sessionID)) else { return nil }
      if try cueState()?.left.contains(where: { $0.holds(for: session) }) != true { try putLeft([session]) }
      return session
    }
  }

  public func takeBack(_ sessionID: String) throws -> Bool {
    try write {
      guard let session = try sessionState(sessionID), try cueState()?.left.contains(where: { $0.holds(for: session) }) == true else { return false }
      try putLeft([], removing: [sessionID])
      return true
    }
  }

  @discardableResult
  func putLeft(_ sessions: [SessionState], removing: [String] = []) throws -> Bool {
    let current = try cueState()
    let replaced = Set(sessions.map(\.sessionID) + removing)
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
