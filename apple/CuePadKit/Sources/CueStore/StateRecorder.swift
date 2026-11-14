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

  /// 工作中细节的最短写入间隔（会话与 Cue 同一个）：每次写入都是一次整条记录的上传与各端的下载。放宽到 15 秒不拖慢该快的：
  /// 状态转换（开始工作、等你、做完、出错）不受它管；回答（对话与近况）不经这里写，提交后随即上传（`RecordSender`）；
  /// 正在说的话只在 Mac 的内存里逐字显示（`LiveDraft`），不靠同步。
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

  /// 写一个会话此刻的样子（桥上的会话产出的 `SessionSnapshot`，`SessionMirror` 交来）：会话记录只经这里写。
  /// 快照上说不上来的几项沿用上一次写下的（`SessionSnapshot.keepingUnknown`）。
  /// 返回这次写入置位的通知标志（没有置位为 nil）；置位的那一版由同步层马上传（`Table.urgent`）。
  @discardableResult
  public func update(_ snapshot: SessionSnapshot) async throws -> AlertKind? {
    let sessionID = snapshot.sessionID
    var session = sessions[sessionID] ?? Session()
    let now = timing.now()
    let previous = session.pace.content
    var content = snapshot
    if let previous { content.keepingUnknown(from: previous) }
    // 工作中总有这段连续处理的起点（界面的"已运行"、停止的进度都从它算）：桥上的会话由扩展给，
    // 不带时间的调用方（演示、测试）从进入工作算
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

  /// 演示与测试只写关心的几项：在上一次写下的样子上改给了的（nil 沿用），`question`、`detail` 与 `failure` 每次整体替换；
  /// 第一次写、没给计时的从此刻算。落盘同 `update(_:)`。
  @discardableResult
  public func update(
    sessionID: String, state: WorkState, detail: String? = nil, failure: FailureKind? = nil, title: String? = nil, directory: String? = nil,
    projectID: UUID? = nil, question: Question? = nil, times: SessionTimes? = nil, turnStartedAt: Date? = nil, launchToken: String? = nil, hosted: Bool? = nil,
    subagents: [SubagentState]? = nil, modelState: ModelState? = nil, context: ContextUsage? = nil, commands: [SlashCommand]? = nil,
    agent: AgentKind? = nil, process: SessionProcess? = nil
  ) async throws -> AlertKind? {
    var snapshot = sessions[sessionID]?.pace.content ?? SessionSnapshot(sessionID: sessionID, state: state, times: SessionTimes(stateSince: timing.now(), busySince: nil))
    snapshot.state = state
    snapshot.detail = detail
    snapshot.failure = failure
    snapshot.question = question
    if let title { snapshot.title = title }
    if let directory { snapshot.directory = directory }
    if let projectID { snapshot.projectID = projectID }
    if let times { snapshot.times = times }
    if let turnStartedAt { snapshot.turnStartedAt = turnStartedAt }
    if let launchToken { snapshot.launchToken = launchToken }
    if let hosted { snapshot.hosted = hosted }
    if let subagents { snapshot.subagents = subagents }
    if let modelState { snapshot.modelState = modelState }
    if let context { snapshot.context = context }
    if let commands { snapshot.commands = commands }
    if let agent { snapshot.agent = agent }
    if let process { snapshot.process = process }
    return try await update(snapshot)
  }

  /// 源端确认实际结束：状态与领取时固定的请求集合一并落盘；没有请求身份的状态更新不确认投送。
  public func end(sessionID: String, confirming requests: Set<UUID> = []) async throws {
    sessions.removeValue(forKey: sessionID)?.pace.timer?.task.cancel()
    let now = timing.now()
    try await persist { [store, hostID, bootID] in try await store.endSessionState(host: hostID, sessionID: sessionID, bootID: bootID, at: now, confirming: requests) }
  }

  /// 启动对账（历史回填完成后）：歇着的托管会话没有会话文件索引的（文件被删的、从没落盘的）删掉记录；此刻在线的（本记录器正在跟的）不动——
  /// 它们的记录由状态变化自己写，对账与写入在这里排在同一条任务链上，不会删掉刚建立的会话。
  /// 只对账这一家（它的索引刚回填完）：别家的索引此刻可能不全（没接入的不回填），它们的记录不动。
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

  private func flush(_ sessionID: String, timer: UUID) async {
    guard var session = sessions[sessionID], let content = session.pace.due(timer) else { return }
    let write = commit(sessionID, &session, content, at: timing.now())
    sessions[sessionID] = session
    // 定时写入没有调用方可报告；记为未写入，下一次更新会重写
    do { try await persist(write) } catch { sessions[sessionID]?.pace.forget(content) }
  }

  /// 挂起的写入等 `wait` 秒再交给 `fire`（带这个计时任务的身份，`Pace.due` 据此核对）；被取消（取代、丢弃）就不写。
  func after(_ wait: TimeInterval, _ fire: @escaping @Sendable (StateRecorder, UUID) async -> Void) -> Owned {
    Owned.spawn { [timing] id in
      guard (try? await timing.sleep(.seconds(wait))) != nil else { return }
      await fire(self, id)
    }
  }

  /// 把 `content` 记为已写入，返回对应的落盘操作。`notify` 是手机通知标志（只发 `AlertKind.entering` 定义的两种转换）：
  /// 一次性事件，只存在于未上传的版本上——置位后，同一状态下的后续写入（如仍在等、只换了问题文本）在上传之前沿用它
  /// （见 `writeSessionState`）；服务端接受上传即清掉（`CueStore.markPushed`），此后本机的任何改动都不会再带上，订阅不会为同一次
  /// 等待重复通知。状态一旦前进（如用户答完回到思考中），未上传的标志随之作废——已恢复工作的会话不该再提示"等你确认"。
  /// 会话结束（`end`）清掉标志，未上传的也不再通知。
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
