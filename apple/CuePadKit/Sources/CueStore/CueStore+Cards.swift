import CueText
import Foundation

extension CueStore {
  /// 新灵感放在所在项目的最前（没指定的进默认项目）。项目必须存在且未在回收站，否则抛 `invalidProject`。
  public func createCard(in project: UUID = Project.defaultID, body: String = "") throws -> Card {
    try write {
      try requireLiveProject(project)
      return try insertCard(body, project: project, parent: nil, todo: false, sortKey: SortKey.before(firstTopKey(in: project)))
    }
  }

  /// 新任务（要做的卡片）放在所在项目顶层的最前。正文不能为空，否则抛 `blankTaskContent`；第一行是标题，其余是它的正文（`CueLines.split`）。
  public func createTask(_ body: String, in project: UUID = Project.defaultID) throws -> Card {
    try requireContent(body)
    return try write {
      try requireLiveProject(project)
      return try insertCard(body, project: project, parent: nil, todo: true, sortKey: SortKey.before(firstTopKey(in: project)))
    }
  }

  /// 新子任务放在 `parent` 的下级最后，项目随它。上级不是任务抛 `invalidParent`，已在第 `Card.maxTaskDepth` 级抛 `taskTooDeep`。
  /// 上级原本是叶子时，它的会话移到这个新子任务上（这一步就是已经在做的那件事，`CardLinks` 的规则）；上级的正文留在上级。
  /// 上级已完成的不再算做完（`reopen`）：加子任务是明说还有活。
  public func createTask(_ body: String, under parent: UUID) throws -> Card {
    try requireContent(body)
    return try write {
      guard let link = try link(of: parent), link.isTask else { throw CueStoreError.invalidParent }
      guard try ancestors(of: parent).count + 1 < Card.maxTaskDepth else { throw CueStoreError.taskTooDeep }
      let last = try db.first("SELECT MAX(sortKey) FROM cards WHERE parentID = ?", [parent]) { $0.textOrNil(0) } ?? nil
      let step = try insertCard(body, project: link.project, parent: parent, todo: true, sortKey: SortKey.after(last))
      try settle(around: [parent])  // 叶子加了第一个子任务：它的会话移到这个子任务上
      try reopen([parent])
      return try find(Card.self, step.id) ?? step
    }
  }

  /// 任务此刻干活的叶子：任务自己是叶子就是它；有子任务的是第一个没完成的子任务，没有就第一个子任务（`CardLinks.home(of:)`）。
  /// 开工、绑会话、交话都落到它上面。`task` 必须是任务。
  func homeLeaf(_ task: UUID) throws -> UUID { try CardLinks(db, around: [task]).home(of: task) }

  /// 改正文、置顶、变量取值。归属、结构、状态、删除对调用方只读，各有专门的方法（编译期保证）。
  public func updateCard(_ id: UUID, _ edit: @Sendable (inout Card) -> Void) throws {
    try write {
      guard var card = try find(Card.self, id) else { throw CueStoreError.notFound }
      edit(&card)
      card.modifiedAt = Date.stamp
      try update(card)
      try registerAttachments(in: card.body)
    }
  }

  /// 把灵感接到任务正文后面（填好的变量换成值，没填的留占位符），灵感进回收站，一个事务（拖一条灵感到任务上）：灵感说的是这件事的一部分，接上后在任务里接着读、开工时一起交出去。
  /// 返回回执（`undo` 把正文改回、灵感恢复）。灵感不在了抛 `notFound`，落点不是任务抛 `notATask`。
  @discardableResult
  public func mergeIdea(_ idea: UUID, into task: UUID) throws -> CardChange {
    try write {
      guard let card = try find(Card.self, idea), !card.isTask, card.deletedAt == nil else { throw CueStoreError.notFound }
      guard let target = try find(Card.self, task) else { throw CueStoreError.notFound }
      guard target.isTask else { throw CueStoreError.notATask }
      // 灵感填好的变量值随正文写进去：值记在灵感上，接过去后任务读不到，留着占位符就丢了它的意思
      let now = Date.stamp, added = CueVariables.fill(card.body, values: card.variableValues).trimmingCharacters(in: .whitespacesAndNewlines)
      if !added.isEmpty {
        let kept = target.body.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.run("UPDATE cards SET body = ?, modifiedAt = ? WHERE id = ?", [kept + "\n\n" + added, now, task])
      }
      try trashRow(card, at: now)
      return .merge(idea: idea, task: task, body: target.body)
    }
  }

  /// 挪到 `slot` 里 `previous` 之后（nil = 最前），下级随它走、项目随新位置。卡片墙上的排序、换项目、缩进、
  /// 挂成子任务、灵感挂到任务下都是它。只能挂到任务下、不能挂到自己或自己的下级下（`invalidParent`），任务的子树超过 `Card.maxTaskDepth` 级任务抛 `taskTooDeep`。
  /// 任务挂成子任务后，上级原来的会话按叶子的规则移到子任务上（`settle`）。
  /// 返回回执（`undo` 把它放回原来的位置：原来的上级或项目、原来的前一个同级）。
  @discardableResult
  public func moveCard(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws -> CardChange {
    try write { try relocate(id, to: slot, after: previous) }
  }

  @discardableResult
  func relocate(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws -> CardChange {
    guard let current = try link(of: id) else { throw CueStoreError.notFound }
    let origin = Self.siblingScope(current), originKey = current.parent ?? current.project
    let siblings = try db.query("SELECT id FROM cards WHERE (\(origin)) ORDER BY sortKey, id", [originKey]) { $0.uuid(0) }
    let before = siblings.firstIndex(of: id).flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
    let from: CardSlot = current.parent.map(CardSlot.under) ?? .top(project: current.project)
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

  /// 项目顶层（灵感与任务共用一个手动顺序）最前面的排序键。
  private func firstTopKey(in project: UUID) throws -> String? {
    try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID = ? AND parentID IS NULL", [project]) { $0.textOrNil(0) } ?? nil
  }

  private func insertCard(_ body: String, project: UUID, parent: UUID?, todo: Bool, sortKey: String) throws -> Card {
    let now = Date.stamp
    let card = Card(
      id: UUID(), projectID: project, body: body, isPinned: false, variableValues: [:], conflictOf: nil, sortKey: sortKey,
      deletedAt: nil, createdAt: now, modifiedAt: now, parentID: parent, todoAt: todo ? now : nil)
    try insert(card)
    try registerAttachments(in: body)
    return card
  }

  /// 下级（含已归档的）按原顺序提到 `card` 的位置（挂到它的上级下、排在它之后）：去掉要做、进回收站时用。返回被提的下级，`undo` 靠它放回去。
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

  /// 同级的范围：同一上级下，或同一项目的顶层。
  private static func siblingScope(_ link: CardLinks.Link) -> String {
    link.parent == nil ? "parentID IS NULL AND projectID = ?" : "parentID = ?"
  }

  static func idList(_ ids: some Sequence<UUID>) -> String {
    "[" + ids.map { "\"\($0.uuidString.lowercased())\"" }.joined(separator: ",") + "]"
  }

  /// 待用户处理的正文冲突：原卡与副本都还在的卡对，最近产生的在前。
  public func conflicts() throws -> [CardConflict] {
    try select(
      Card.self,
      where: "conflictOf IS NOT NULL AND deletedAt IS NULL AND conflictOf IN (SELECT id FROM cards)",
      orderBy: "modifiedAt DESC, id"
    ).compactMap { copy in
      try copy.conflictOf.flatMap { try find(Card.self, $0) }.map { CardConflict(original: $0, copy: copy) }
    }
  }

  /// 选定保留的版本并删除副本。原卡已不存在时，副本是唯一的版本：转为普通卡，不删除。
  public func resolveConflict(copy id: UUID, keep choice: ConflictChoice) throws {
    try reportingFileFailures {
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

  /// 把 `id` 放到同一范围内 `previous` 之后：只改它自己的排序键；
  /// 两侧键相同（多设备并发产生）时，重排该范围内所有键。
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
