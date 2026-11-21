import CueText
import Foundation

extension CueStore {
  public func createCard(in project: UUID = Project.defaultID, body: String = "", ifProjectMissing: MissingProject = .reject) throws -> Card {
    try write {
      let project = try requireLiveProject(project, ifMissing: ifProjectMissing)
      return try insertCard(body, project: project, parent: nil, todo: false, sortKey: SortKey.before(firstTopKey(in: project)))
    }
  }

  public func createCard(in project: UUID = Project.defaultID, body: String, capture: String, ifProjectMissing: MissingProject = .reject) throws -> Card? {
    try write {
      let key = Self.captureKey(capture)
      guard try syncState(key) == nil else { return nil }
      let project = try requireLiveProject(project, ifMissing: ifProjectMissing)
      let card = try insertCard(body, project: project, parent: nil, todo: false, sortKey: SortKey.before(firstTopKey(in: project)))
      try db.run("INSERT INTO syncState (key, value) VALUES (?, ?)", [key, Data()])
      return card
    }
  }

  public func finishCapture(_ capture: String) throws { try setSyncState(Self.captureKey(capture), nil) }

  private static func captureKey(_ capture: String) -> String { "capture:\(capture)" }

  public func createTask(_ body: String, in project: UUID = Project.defaultID, ifProjectMissing: MissingProject = .reject) throws -> Card {
    try requireContent(body)
    return try write {
      let project = try requireLiveProject(project, ifMissing: ifProjectMissing)
      return try insertCard(body, project: project, parent: nil, todo: true, sortKey: SortKey.before(firstTopKey(in: project)))
    }
  }

  public func createTask(_ body: String, under parent: UUID) throws -> Card {
    try requireContent(body)
    return try write {
      guard let link = try link(of: parent), link.isTask else { throw CueStoreError.invalidParent }
      guard try ancestors(of: parent).count + 1 < Card.maxTaskDepth else { throw CueStoreError.taskTooDeep }
      let last = try db.first("SELECT MAX(sortKey) FROM cards WHERE parentID = ?", [parent]) { $0.textOrNil(0) } ?? nil
      let step = try insertCard(body, project: link.project, parent: parent, todo: true, sortKey: SortKey.after(last))
      try settle(around: [parent])
      try reopen([parent])
      return try find(Card.self, step.id) ?? step
    }
  }

  func homeLeaf(_ task: UUID) throws -> UUID { try CardLinks(db, around: [task]).home(of: task) }

  public func updateCard(_ id: UUID, _ edit: @Sendable (inout Card) -> Void) throws {
    try write {
      guard var card = try find(Card.self, id) else { throw CueStoreError.notFound }
      edit(&card)
      card.modifiedAt = Date.stamp
      try update(card)
      try registerAttachments(in: card.body)
    }
  }

  @discardableResult
  public func mergeIdea(_ idea: UUID, into task: UUID) throws -> CardChange {
    try write {
      let (card, added) = try ideaText(idea)
      guard let target = try find(Card.self, task) else { throw CueStoreError.notFound }
      guard target.isTask else { throw CueStoreError.notATask }
      let now = Date.stamp
      if !added.isEmpty {
        let kept = target.body.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.run("UPDATE cards SET body = ?, modifiedAt = ? WHERE id = ?", [kept + "\n\n" + added, now, task])
      }
      try trashRow(card, at: now)
      let written = try find(Card.self, task)?.modifiedAt ?? target.modifiedAt
      return .merge(idea: idea, task: task, body: target.body, modifiedAt: written)
    }
  }

  public func createTask(fromIdea idea: UUID) throws -> (task: Card, change: CardChange) {
    try write {
      let (card, body) = try ideaText(idea)
      try requireContent(body)
      let task = try insertCard(body, project: card.projectID, parent: nil, todo: true, sortKey: SortKey.before(firstTopKey(in: card.projectID)))
      try trashRow(card, at: Date.stamp)
      return (task, .spawn(idea: idea, task: task.id, modifiedAt: task.modifiedAt))
    }
  }

  private func ideaText(_ id: UUID) throws -> (Card, String) {
    guard let card = try find(Card.self, id), !card.isTask, card.deletedAt == nil else { throw CueStoreError.notFound }
    return (card, CueVariables.fill(card.body, values: card.variableValues).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @discardableResult
  public func moveCard(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws -> CardChange {
    try write { try relocate(id, to: slot, after: previous) }
  }

  func position(of id: UUID, _ current: CardLinks.Link) throws -> (slot: CardSlot, before: UUID?) {
    let siblings = try db.query(
      "SELECT id FROM cards WHERE (\(Self.siblingScope(current))) ORDER BY sortKey, id", [current.parent ?? current.project]) { $0.uuid(0) }
    let before = siblings.firstIndex(of: id).flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
    return (current.parent.map(CardSlot.under) ?? .top(project: current.project), before)
  }

  @discardableResult
  func relocate(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws -> CardChange {
    guard let current = try link(of: id) else { throw CueStoreError.notFound }
    let (from, before) = try position(of: id, current)
    let destination: CardLinks.Link
    switch slot {
    case .top(let project):
      try requireLiveProject(project)
      destination = CardLinks.Link(parent: nil, project: project, isTask: current.isTask)
    case .under(let parent):
      let above = try ancestors(of: parent)
      guard let target = try link(of: parent), target.isTask, parent != id, !above.contains(id) else {
        throw CueStoreError.invalidParent
      }
      if current.isTask, above.count + 1 + (try taskHeight(of: id)) > Card.maxTaskDepth { throw CueStoreError.taskTooDeep }
      destination = CardLinks.Link(parent: parent, project: target.project, isTask: current.isTask)
    }
    let now = Date.stamp
    try db.run("UPDATE cards SET parentID = ?, modifiedAt = ? WHERE id = ?", [destination.parent, now, id])
    if destination.project != current.project {
      try db.run(
        "UPDATE cards SET projectID = ?, modifiedAt = ? WHERE id IN (\(Self.subtree(from: "SELECT ?3")))", [destination.project, now, id])
    }
    try place(scope: Self.siblingScope(destination), [destination.parent ?? destination.project], id: id, after: previous)
    if current.isTask, let parent = destination.parent { try settle(around: [parent]) }
    return .move(id: id, from: from, after: before)
  }

  private func requireContent(_ content: String) throws {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankTaskContent }
  }

  func firstTopKey(in project: UUID) throws -> String? {
    try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID = ? AND parentID IS NULL", [project]) { $0.textOrNil(0) } ?? nil
  }

  func insertCard(_ body: String, project: UUID, parent: UUID?, todo: Bool, sortKey: String) throws -> Card {
    let now = Date.stamp
    let card = Card(
      id: UUID(), projectID: project, body: body, isPinned: false, variableValues: [:], conflictOf: nil, sortKey: sortKey,
      deletedAt: nil, createdAt: now, modifiedAt: now, parentID: parent, todoAt: todo ? now : nil)
    try insert(card)
    try registerAttachments(in: body)
    return card
  }

  @discardableResult
  func liftChildren(of card: Card, at now: Date) throws -> [UUID] {
    let children = try db.query("SELECT id FROM cards WHERE parentID = ? ORDER BY sortKey, id", [card.id]) { $0.uuid(0) }
    guard !children.isEmpty else { return [] }
    let link = CardLinks.Link(parent: card.parentID, project: card.projectID, isTask: card.isTask)
    let upper = try db.first(
      "SELECT MIN(sortKey) FROM cards WHERE (\(Self.siblingScope(link))) AND sortKey > ?", [card.parentID ?? card.projectID, card.sortKey]
    ) { $0.textOrNil(0) } ?? nil
    var lower = card.sortKey
    for child in children {
      let key = SortKey.between(lower, upper) ?? SortKey.after(lower)
      try db.run("UPDATE cards SET parentID = ?, sortKey = ?, modifiedAt = ? WHERE id = ?", [card.parentID, key, now, child])
      lower = key
    }
    return children
  }

  private static func siblingScope(_ link: CardLinks.Link) -> String {
    link.parent == nil ? "parentID IS NULL AND projectID = ?" : "parentID = ?"
  }

  static func idList(_ ids: some Sequence<UUID>) -> String {
    "[" + ids.map { "\"\($0.uuidString.lowercased())\"" }.joined(separator: ",") + "]"
  }

  public func conflicts() throws -> [CardConflict] {
    try select(
      Card.self,
      where: "conflictOf IS NOT NULL AND deletedAt IS NULL AND conflictOf IN (SELECT id FROM cards)",
      orderBy: "modifiedAt DESC, id"
    ).compactMap { copy in
      try copy.conflictOf.flatMap { try find(Card.self, $0) }.map { CardConflict(original: $0, copy: copy) }
    }
  }

  public func resolveConflict(copy id: UUID, keep choice: ConflictChoice) throws {
    try removingFiles {
      try write {
        guard let copy = try find(Card.self, id), let originalID = copy.conflictOf else {
          throw CueStoreError.notAConflictCopy
        }
        guard var original = try find(Card.self, originalID) else {
          try db.run("UPDATE cards SET conflictOf = NULL, modifiedAt = ? WHERE id = ?", [Date.stamp, id])
          return []
        }
        if case .copy = choice {
          original.body = copy.body
          original.modifiedAt = Date.stamp
          try update(original)
        }
        return try reclaimAttachments(purgeCards(where: "id = ?", [id]))
      }
    }
  }

  fileprivate func place(
    scope: String, _ scopeArguments: [any SQLBindable] = [], id: UUID, after previous: UUID?
  ) throws {
    let siblings = try db.query(
      "SELECT id, sortKey FROM cards WHERE (\(scope)) AND id != ? ORDER BY sortKey, id",
      scopeArguments + [id]
    ) { (id: $0.uuid(0), key: $0.text(1)) }

    var position = 0
    if let previous {
      guard let index = siblings.firstIndex(where: { $0.id == previous }) else {
        throw CueStoreError.notFound
      }
      position = index + 1
    }
    let lower = position > 0 ? siblings[position - 1].key : nil
    let upper = position < siblings.count ? siblings[position].key : nil

    let assignments: [(id: UUID, key: String)]
    if let key = SortKey.between(lower, upper) {
      assignments = [(id, key)]
    } else {
      var order = siblings.map(\.id)
      order.insert(id, at: position)
      assignments = Array(zip(order, SortKey.sequence(count: order.count)))
    }
    let now = Date.stamp
    for (rowID, key) in assignments {
      try db.run("UPDATE cards SET sortKey = ?, modifiedAt = ? WHERE id = ?", [key, now, rowID])
      guard db.changes > 0 else { throw CueStoreError.notFound }
    }
  }
}
