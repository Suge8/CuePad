#if DEBUG
import Foundation

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

  public func seedAgeCueMessages(by seconds: TimeInterval) throws {
    let ms = Int64(seconds * 1000)
    try write {
      try db.exec(
        """
        UPDATE cueMessages SET createdAt = createdAt - \(ms), answeredAt = answeredAt - \(ms);
        UPDATE marks SET modifiedAt = modifiedAt - \(ms) WHERE kind = 'cueRead';
        """)
    }
  }
}

extension StateRecorder {
  @discardableResult
  public func update(
    sessionID: String, state: WorkState, detail: String? = nil, failure: FailureKind? = nil, title: String? = nil, directory: String? = nil,
    projectID: UUID? = nil, question: Question? = nil, times: SessionTimes? = nil, turnStartedAt: Date? = nil, turnOpener: TurnOpener? = nil, launchToken: String? = nil, hosted: Bool? = nil,
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
    if let turnOpener { snapshot.turnOpener = turnOpener }
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
