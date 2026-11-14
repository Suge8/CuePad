#if DEBUG
import Foundation

/// 演示库与性能测量库（Debug 构建的视觉验收与测量，见 `DemoLibrary`、`PerfLibrary`）：项目与灵感、任务按给定的修改时间原样写入，
/// 墙和"更早"分组才有真实的时间分布；走正常入口建不出这种时间。
public struct SeedProject: Sendable {
  public var name: String, icon: String, color: String, pinned: Bool

  public init(name: String, icon: String, color: String, pinned: Bool) {
    (self.name, self.icon, self.color, self.pinned) = (name, icon, color, pinned)
  }
}

public struct SeedCard: Sendable {
  public enum Kind: Sendable { case idea, task, doneTask }

  public var project: Int?
  public var body: String
  public var pinned: Bool
  public var modifiedAt: Date
  public var kind: Kind

  public init(project: Int?, body: String, pinned: Bool = false, modifiedAt: Date, kind: Kind = .idea) {
    (self.project, self.body, self.pinned, self.modifiedAt, self.kind) = (project, body, pinned, modifiedAt, kind)
  }
}

/// 演示记忆的一条：记下的时刻原样写入，记忆页才有"刚刚""昨天""几月几日"的分布。
public struct SeedCueLine: Sendable {
  public var text: String, source: CueLineSource, pinned: Bool, createdAt: Date
  public var remindAt: Date?, repeats: CueRepeat?, task: UUID?

  public init(
    _ text: String, source: CueLineSource, pinned: Bool = false, createdAt: Date, remindAt: Date? = nil, repeats: CueRepeat? = nil, task: UUID? = nil
  ) {
    (self.text, self.source, self.pinned, self.createdAt) = (text, source, pinned, createdAt)
    (self.remindAt, self.repeats, self.task) = (remindAt, repeats, task)
  }
}

extension CueStore {
  public func seed(cueLines: [SeedCueLine]) throws {
    try write {
      for line in cueLines {
        try insert(
          CueMemoryLine(
            id: UUID(), text: line.text, pinned: line.pinned, source: .known(line.source), remindAt: line.remindAt,
            repeats: line.repeats, task: line.task, createdAt: line.createdAt,
            modifiedAt: line.createdAt, deletedAt: nil))
      }
    }
  }

  public func seed(projects: [SeedProject], cards: [SeedCard]) throws {
    let now = Date.stamp
    try write {
      let ids = try projects.map { project in
        let id = UUID()
        try insert(
          Project(
            id: id, name: project.name, icon: project.icon, color: project.color, isPinned: project.pinned, intro: nil, deletedAt: nil,
            createdAt: now, modifiedAt: now))
        return id
      }
      for kind in [SeedCard.Kind.idea, .task] {
        let group = cards.filter { ($0.kind == .idea) == (kind == .idea) }
        for (card, key) in zip(group, SortKey.sequence(count: group.count)) {
          try insert(
            Card(
              id: UUID(), projectID: card.project.map { ids[$0] } ?? Project.defaultID, body: card.body, isPinned: card.pinned, variableValues: [:],
              conflictOf: nil, sortKey: key, deletedAt: nil, createdAt: card.modifiedAt, modifiedAt: card.modifiedAt,
              todoAt: card.kind == .idea ? nil : card.modifiedAt, completedAt: card.kind == .doneTask ? card.modifiedAt : nil))
        }
      }
    }
  }

  /// 演示里说出去一会儿了的话（看没回执超时的样子）：把已有的对话整体往前挪 `seconds` 秒（先后不变）。
  public func seedAgeCueMessages(by seconds: TimeInterval) throws {
    // 答的时刻（你的回答按它排在对话里）与读到哪（`CueRead`）都是对话里的时刻，跟着挪
    let ms = Int64(seconds * 1000)
    try write {
      try db.exec(
        """
        UPDATE cueMessages SET createdAt = createdAt - \(ms), answeredAt = answeredAt - \(ms);
        UPDATE cueRead SET modifiedAt = modifiedAt - \(ms);
        """)
    }
  }
}

extension StateRecorder {
  /// 演示与测试只写关心的几项：在上一次写下的样子上改给了的（nil 沿用），`question`、`detail` 与 `failure` 每次整体替换；
  /// 第一次写、没给计时的从此刻算。落盘同 `update(_:)`。
  @discardableResult
  public func update(
    sessionID: String, state: WorkState, detail: String? = nil, failure: FailureKind? = nil, title: String? = nil, directory: String? = nil,
    projectID: UUID? = nil, question: Question? = nil, times: SessionTimes? = nil, turnStartedAt: Date? = nil, launchToken: String? = nil, hosted: Bool? = nil,
    subagents: [SubagentState]? = nil, modelState: ModelState? = nil, context: ContextUsage? = nil, commands: [SlashCommand]? = nil,
    agent: AgentKind? = nil, process: SessionProcess? = nil
  ) async throws -> AlertKind? {
    var snapshot = latest(sessionID) ?? SessionSnapshot(sessionID: sessionID, state: state, times: SessionTimes(stateSince: timing.now(), busySince: nil))
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
}
#endif
