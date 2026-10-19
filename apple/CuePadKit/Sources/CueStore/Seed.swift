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

  /// 所属项目在 `seed(projects:cards:)` 的 `projects` 里的下标；nil 是未分类。
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

  public init(_ text: String, source: CueLineSource, pinned: Bool = false, createdAt: Date) {
    (self.text, self.source, self.pinned, self.createdAt) = (text, source, pinned, createdAt)
  }
}

extension CueStore {
  /// 一次写入演示记忆（按记下的时刻排位，与正常记下的一样）。
  public func seed(cueLines: [SeedCueLine]) throws {
    try write {
      for line in cueLines {
        try insert(
          CueMemoryLine(
            id: UUID(), text: line.text, pinned: line.pinned, source: .known(line.source), remindAt: nil, createdAt: line.createdAt,
            modifiedAt: line.createdAt, deletedAt: nil))
      }
    }
  }

  /// 一次写入全部项目与卡片（同类按给定顺序排）。
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
              id: UUID(), projectID: card.project.map { ids[$0] }, body: card.body, isPinned: card.pinned, variableValues: [:],
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
#endif
