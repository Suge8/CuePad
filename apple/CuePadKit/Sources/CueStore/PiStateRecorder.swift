import Foundation

/// 把 Pi 会话的状态变化（每个会话一条）与 Cue 此刻的样子（`updateCue`）写成同步记录，节拍同一套（`Pace`，间隔 `minInterval`）：
/// - 开始工作、等你确认、完成、出错，以及会话的标题或项目变化：立即写；
/// - 工作中的细节变化（输出、调用哪个工具）：合并，两次写入之间至少隔 `minInterval`（默认 `detailInterval`），期间只保留最新的一次；
/// - 近况（`PiRecap`）变化：立即写；
/// - 与已写入内容相同的更新不再写；会话的进程退出时按 `exited` 处理记录（历史、歇着、删除）并丢弃挂起的更新；用户结束会话时
///   标为已结束（近况留给手机看，记录与会话文件同存亡，见 `CueStore.retainPiSessions`）。
///
/// actor 在 await 处可重入：状态只在 await 之前改完，不跨 await 持有副本；会话与 Cue 的落盘按决定的先后串成同一条任务链，
/// 后决定的写入（含删除）不会被先决定的覆盖。
public actor PiStateRecorder {
  private struct Session {
    var pace = Pace<PiStateContent>()
    /// 已写入内容的目录记录（模型与命令没变时沿用，不重算内容的 id）
    var catalog: AgentCatalog?
  }

  /// 工作中细节的最短写入间隔（会话与 Cue 同一个）：每次写入都是一次整条记录的上传与各端的下载。放宽到 15 秒不拖慢该快的：
  /// 状态转换（开始工作、等你、做完、出错）不受它管；回答（对话与近况）不经这里写，提交后随即上传（`RecordSender`）；
  /// 正在说的话只在 Mac 的内存里逐字显示（`PiDraft`），不靠同步。
  public static let detailInterval: Duration = .seconds(15)

  public nonisolated let store: CueStore
  public nonisolated let hostID: String
  let minInterval: Duration
  let timing: Timing
  private var sessions: [String: Session] = [:]
  /// Cue 此刻的样子（`PiStateRecorder+Cue.swift`）
  var cue = Pace<CueStateContent>()
  private var tail: Task<Void, Never>?

  public init(store: CueStore, hostID: String, minInterval: Duration = detailInterval, timing: Timing = .system) {
    self.store = store
    self.hostID = hostID
    self.minInterval = minInterval
    self.timing = timing
  }

  /// 没给的字段（nil）沿用上一次的值；`question`、`detail` 与 `failure` 每次整体替换。
  /// 返回这次写入置位的通知标志（没有置位为 nil）：调用方据此立即上传这一条，通知不排在其余待推送后面。
  @discardableResult
  public func update(
    sessionID: String, state: PiWorkState, detail: String? = nil, failure: PiFailure? = nil, title: String? = nil, directory: String? = nil,
    projectID: UUID? = nil, question: PiQuestion? = nil, times: PiTimes? = nil, turnStartedAt: Date? = nil, launchToken: String? = nil, hosted: Bool? = nil,
    subagents: [PiSubagentState]? = nil, modelState: PiModelState? = nil, context: PiContextUsage? = nil, commands: [PiSlashCommand]? = nil,
    agent: AgentKind? = nil, process: PiProcess? = nil
  ) async throws -> PiAlert? {
    var session = sessions[sessionID] ?? Session()
    let now = timing.now()
    let previous = session.pace.content.map { (state: $0.state, since: $0.times.stateSince) }
    // 调用方给的计时基准；没给过时（测试、演示）用第一次写入的时间，之后不变
    var content = session.pace.content ?? PiStateContent(state: state, times: PiTimes(stateSince: now, busySince: nil))
    content.state = state
    content.detail = detail
    content.failure = failure
    content.question = question
    if let title { content.title = title }
    if let directory { content.directory = directory }
    if let projectID { content.projectID = projectID }
    if let times { content.times = times }
    if let turnStartedAt { content.turnStartedAt = turnStartedAt }
    if let launchToken { content.launchToken = launchToken }
    if let hosted { content.hosted = hosted }
    if let subagents { content.subagents = subagents }
    if let modelState { content.modelState = modelState }
    if let context { content.context = context }
    if let commands { content.commands = commands }
    if let agent { content.agent = agent }
    if let process { content.process = process }
    // 工作中总有这段连续处理的起点（界面的"已运行"、停止的进度都从它算）：桥上的会话由扩展给，
    // 不带时间的调用方（演示、测试）从进入工作算
    if state.isWorking, content.times.busySince == nil { content.times.busySince = content.times.stateSince }
    switch session.pace.offer(content, at: now, interval: minInterval) {
    case .skip:
      sessions[sessionID] = session
      return nil
    case .wait(let wait):
      session.pace.timer = after(wait) { await $0.flush(sessionID) }
      sessions[sessionID] = session
      return nil
    case .now:
      let alert = PiAlert.entering(state, since: content.times.stateSince, from: previous)
      let write = commit(sessionID, &session, content, notify: alert, at: now)
      sessions[sessionID] = session
      do { try await persist(write) } catch {
        sessions[sessionID]?.pace.forget(content)
        throw error
      }
      return alert
    }
  }

  /// 用户结束会话：记录标为已结束，进历史（不算被打断）。
  public func end(sessionID: String) async throws {
    sessions.removeValue(forKey: sessionID)?.pace.timer?.cancel()
    let now = timing.now()
    try await persist { [store, hostID] in try await store.endPiState(host: hostID, sessionID: sessionID, at: now) }
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
  /// - 其余（终端里的 Pi 退出）：记为已结束，进历史。
  /// 后两种在记录上手上还有活时记为做到一半被打断（`PiWorkState.interrupted`：崩溃、被杀）。
  /// 托管的会话要结束，由用户的结束请求写 `end`。
  public func exited(sessionID: String, spoke: Bool) async throws {
    sessions.removeValue(forKey: sessionID)?.pace.timer?.cancel()
    let id = sessionID
    let now = timing.now()
    if spoke {
      try await persist { [store, hostID] in try await store.losePiState(host: hostID, sessionID: id, at: now) }
    } else {
      try await persist { [store, hostID] in try await store.deletePiState(host: hostID, sessionID: id) }
    }
  }

  /// App 启动时对账这台 Mac 上次留下的记录：记下的进程确实没了的按 `exited` 收尾（手上还有活的记为被打断），其余不动——
  /// 进程还在的（托管的 Pi 不随 App 退出，终端里的会话也还开着）与没记下进程的，由桥重新连上后接着写。`running` 判断记下的进程是不是还是那一个。
  /// 返回对账之前还没收尾的各会话的状态与计时（会话 id → ）：桥据此让重新接上的会话沿用原来的起点（`PiBridge.carryOver`）。
  @discardableResult
  public func reset(running: @escaping @Sendable (PiProcess) -> Bool) async throws -> [String: (state: PiWorkState, times: PiTimes)] {
    for session in sessions.values { session.pace.timer?.cancel() }
    sessions = [:]
    let now = timing.now()
    return try await persist { [store, hostID] in try await store.reconcilePiStates(host: hostID, running: running, at: now) }
  }

  private func flush(_ sessionID: String) async {
    guard var session = sessions[sessionID], let content = session.pace.due() else { return }
    let write = commit(sessionID, &session, content, at: timing.now())
    sessions[sessionID] = session
    // 定时写入没有调用方可报告；记为未写入，下一次更新会重写
    do { try await persist(write) } catch { sessions[sessionID]?.pace.forget(content) }
  }

  /// 挂起的写入等 `wait` 秒再交给 `fire`；被取消（取代、丢弃）就不写。
  func after(_ wait: TimeInterval, _ fire: @escaping @Sendable (PiStateRecorder) async -> Void) -> Task<Void, Never> {
    Task { [timing] in
      guard (try? await timing.sleep(.seconds(wait))) != nil else { return }
      await fire(self)
    }
  }

  /// 把 `content` 记为已写入，返回对应的落盘操作。`notify` 是手机通知标志（只发 `PiAlert.entering` 定义的两种转换）：
  /// 一次性事件，只存在于未上传的版本上——置位后，同一状态下的后续写入（如仍在等、只换了问题文本）在上传之前沿用它
  /// （见 `writePiState`）；服务端接受上传即清掉（`CueStore.markPushed`），此后本机的任何改动都不会再带上，订阅不会为同一次
  /// 等待重复通知。状态一旦前进（如用户答完回到思考中），未上传的标志随之作废——已恢复工作的会话不该再提示"等你确认"。
  /// 会话结束（`end`）清掉标志，未上传的也不再通知。
  private func commit(
    _ sessionID: String, _ session: inout Session, _ content: PiStateContent, notify: PiAlert? = nil, at now: Date
  ) -> @Sendable () async throws -> Void {
    let writesCatalog = content.catalogDiffers(from: session.pace.written)
    if writesCatalog { session.catalog = content.catalog(host: hostID, at: now) }
    _ = session.pace.commit(content, at: now)
    return { [store, hostID, catalog = session.catalog] in
      try await store.writePiState(
        sessionID: sessionID, hostID: hostID, content: content, catalog: catalog, writesCatalog: writesCatalog, notify: notify)
    }
  }

  /// 按决定的先后落盘：排在此前所有写入之后。
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
