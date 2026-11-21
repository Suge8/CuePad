import Foundation

/// 把 Pi 会话的状态变化（每个会话一条）与 Cue 此刻的样子（`updateCue`）写成同步记录，节拍同一套（`Pace`）：状态转换与近况（`Recap`）变化立即写；工作中的细节合并，两次写入之间至少隔 `minInterval`（默认 `detailInterval`），期间只保留最新的一次；与已写入内容相同的不再写。
///
/// actor 在 await 处可重入：状态只在 await 之前改完，不跨 await 持有副本；会话与 Cue 的落盘按决定的先后串成同一条任务链，
/// 后决定的写入（含删除）不会被先决定的覆盖。
public actor StateRecorder {
  private struct Session {
    var pace = Pace<SessionSnapshot>()
    var catalog: AgentCatalog?
  }

  public static let detailInterval: Duration = .seconds(15)

  public nonisolated let store: CueStore
  public nonisolated let hostID: String
  let bootID: String?
  let minInterval: Duration
  let timing: Timing
  private var sessions: [String: Session] = [:]
  var cue = Pace<CueStateContent>()
  private var tail: Task<Void, Never>?

  public init(store: CueStore, hostID: String, minInterval: Duration = detailInterval, timing: Timing = .system, bootID: String? = SystemBoot.id) {
    self.store = store
    self.hostID = hostID
    self.bootID = bootID
    self.minInterval = minInterval
    self.timing = timing
  }

  @discardableResult
  public func update(_ snapshot: SessionSnapshot) async throws -> AlertKind? {
    let sessionID = snapshot.sessionID
    var session = sessions[sessionID] ?? Session()
    let now = timing.now()
    let previous = session.pace.content
    var content = snapshot
    if let previous { content.keepingUnknown(from: previous) }
    if content.state.isWorking, content.times.busySince == nil { content.times.busySince = content.times.stateSince }
    switch session.pace.offer(content, at: now, interval: minInterval) {
    case .skip:
      sessions[sessionID] = session
      return nil
    case .wait(let wait):
      session.pace.timer = after(wait) { await $0.flush(sessionID, timer: $1) }
      sessions[sessionID] = session
      return nil
    case .now:
      let alert = AlertKind.entering(content.state, since: content.times.stateSince, from: previous.map { ($0.state, $0.times.stateSince) })
      let write = commit(sessionID, &session, content, notify: alert, at: now)
      sessions[sessionID] = session
      do { try await persist(write) } catch {
        sessions[sessionID]?.pace.forget(content)
        throw error
      }
      return alert
    }
  }

  public func end(sessionID: String, confirming requests: Set<UUID> = []) async throws {
    sessions.removeValue(forKey: sessionID)?.pace.timer?.task.cancel()
    let now = timing.now()
    try await persist { [store, hostID, bootID] in try await store.endSessionState(host: hostID, sessionID: sessionID, bootID: bootID, at: now, confirming: requests) }
  }

  public func dropUnindexedHosted(of agent: AgentKind) async throws {
    let live = Set(sessions.keys)
    try await persist { [store, hostID] in try await store.deleteUnindexedHostedStates(host: hostID, agent: agent, except: live) }
  }

  /// 会话的进程退出了、没有别的进程接着它：什么算历史只在这里定——
  /// - 没留下对话的（`spoke` 为 false：Pi 在第一条消息落盘前不建文件，`--no-session` 也没有）：一句话没说过，不进历史，记录删掉（同步删除）；
  /// - CuePad 后台托管的：闲置退出不算结束，记录留着、歇着，仍在"现在"，发话由本机执行器照常唤醒；
  /// - 其余（旧版本留下的没托管过的，启动对账时收尾）：记为已结束，进历史。
  /// 后两种在记录上手上还有活时记为做到一半被打断（`WorkState.interrupted`：崩溃、被杀）。
  /// 托管的会话要结束，由用户的结束请求写 `end`。
  public func exited(sessionID: String, spoke: Bool) async throws {
    sessions.removeValue(forKey: sessionID)?.pace.timer?.task.cancel()
    let id = sessionID
    let now = timing.now()
    if spoke {
      try await persist { [store, hostID, bootID] in try await store.loseSessionState(host: hostID, sessionID: id, bootID: bootID, at: now) }
    } else {
      try await persist { [store, hostID] in try await store.deleteSessionState(host: hostID, sessionID: id) }
    }
  }

  func latest(_ sessionID: String) -> SessionSnapshot? { sessions[sessionID]?.pace.content }

  private func flush(_ sessionID: String, timer: UUID) async {
    guard var session = sessions[sessionID], let content = session.pace.due(timer) else { return }
    let write = commit(sessionID, &session, content, at: timing.now())
    sessions[sessionID] = session
    do { try await persist(write) } catch { sessions[sessionID]?.pace.forget(content) }
  }

  func after(_ wait: TimeInterval, _ fire: @escaping @Sendable (StateRecorder, UUID) async -> Void) -> Owned {
    Owned.spawn { [timing] id in
      guard (try? await timing.sleep(.seconds(wait))) != nil else { return }
      await fire(self, id)
    }
  }

  private func commit(
    _ sessionID: String, _ session: inout Session, _ content: SessionSnapshot, notify: AlertKind? = nil, at now: Date
  ) -> @Sendable () async throws -> Void {
    let writesCatalog = content.catalogDiffers(from: session.pace.written)
    if writesCatalog { session.catalog = content.catalog(host: hostID, at: now) }
    _ = session.pace.commit(content, at: now)
    return { [store, hostID, bootID, catalog = session.catalog] in
      try await store.writeSessionState(
        sessionID: sessionID, hostID: hostID, bootID: bootID, content: content, catalog: catalog, writesCatalog: writesCatalog, notify: notify)
    }
  }

  func persist<T: Sendable>(_ write: @escaping @Sendable () async throws -> T) async throws -> T {
    let previous = tail
    let task = Task {
      await previous?.value
      return try await write()
    }
    tail = Task { _ = await task.result }
    return try await task.value
  }
}
