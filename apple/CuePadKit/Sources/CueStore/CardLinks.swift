import Foundation

/// 未删除卡片的层级关系（id → 上级、项目、是不是任务等），一次读出：整库的供远端变更后收敛（`repairs`），
/// 只读几个任务和它们的下级的供本机写入时问"提示词该落在哪"（`home(of:)`）与收敛（`CueStore.settle`）。
/// 上级不在（没到、在回收站）的按顶层看待。写入时的校验只问需要的几行，见 `CueStore+Tree`。
///
/// 叶子是没有步骤的任务。提示词（不是资料的灵感）是叶子的草稿：只挂在叶子下，一个叶子最多一条；会话也只记在叶子上。
struct CardLinks {
  struct Link: Equatable {
    var parent: UUID?
    var project: UUID?
    var isTask: Bool
    /// 资料（`isPinned`）不是提示词，挂在哪个任务下都行。
    var isPinned = false
    var isDone = false
    var hasSession = false
  }

  private static let columns = "id, parentID, projectID, todoAt IS NOT NULL, isPinned, completedAt IS NOT NULL, piSessionID IS NOT NULL"

  private(set) var links: [UUID: Link]
  /// 全部卡片按同级顺序（排序键、id）排的 id：合并提示词与选落点的步骤都按它。
  private var order: [UUID]
  private var rank: [UUID: Int]
  private var children: [UUID: [UUID]] = [:]

  init(_ db: SQLite) throws {
    self.init(try db.query("SELECT \(Self.columns) FROM cards WHERE deletedAt IS NULL ORDER BY sortKey, id", [], Self.row))
  }

  /// 只读这些任务、它们的下级与下级的下级（步骤和步骤的提示词）。
  init(_ db: SQLite, around tasks: [UUID]) throws {
    let marks = tasks.map { _ in "?" }.joined(separator: ", ")
    self.init(
      try db.query(
        """
        SELECT \(Self.columns) FROM cards WHERE deletedAt IS NULL AND (id IN (\(marks)) OR parentID IN (\(marks))
          OR parentID IN (SELECT id FROM cards WHERE parentID IN (\(marks)))) ORDER BY sortKey, id
        """, tasks + tasks + tasks, Self.row))
  }

  private static func row(_ row: Row) -> (id: UUID, link: Link) {
    (
      row.uuid(0),
      Link(
        parent: row.uuidOrNil(1), project: row.uuidOrNil(2), isTask: row.bool(3), isPinned: row.bool(4), isDone: row.bool(5),
        hasSession: row.bool(6))
    )
  }

  /// 按同级顺序给出的卡片。
  init(_ rows: [(id: UUID, link: Link)]) {
    links = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.link) })
    order = rows.map(\.id)
    rank = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
    for row in rows { if let parent = row.link.parent { children[parent, default: []].append(row.id) } }
  }

  /// 任务的步骤（没删除的下级任务），按顺序。
  private func steps(of task: UUID) -> [UUID] { (children[task] ?? []).filter { links[$0]?.isTask == true } }

  /// 提示词与会话从任务移下来时落在哪个叶子：任务自己是叶子就是它；有步骤的话是第一个没完成的步骤，没有就第一个步骤。
  func home(of task: UUID) -> UUID { Self.leaf(among: steps(of: task), links) ?? task }

  private static func leaf(among steps: [UUID], _ links: [UUID: Link]) -> UUID? { steps.first { links[$0]?.isDone == false } ?? steps.first }

  /// 在库里的上级，自下而上；有环时走到重复处为止。
  func ancestors(of id: UUID) -> [UUID] {
    var chain: [UUID] = [], cursor = links[id]?.parent
    while let parent = cursor, links[parent] != nil, parent != id, !chain.contains(parent) {
      chain.append(parent)
      cursor = links[parent]?.parent
    }
    return chain
  }

  /// 第几级：顶层是 1。只有任务的级别受 `Card.maxTaskDepth` 限制。
  func level(of id: UUID) -> Int { ancestors(of: id).count + 1 }
}

extension CardLinks {
  /// 收敛要改写的东西：卡片的上级与项目，要并掉的提示词，要交接的会话。
  struct Repairs {
    var links: [UUID: Link] = [:]
    /// 留下的那条提示词 → 并进它的其余提示词（按顺序；其余的删掉）。
    var merges: [UUID: [UUID]] = [:]
    /// 有步骤的任务记着的会话 → 接手的叶子（`home(of:)`）；叶子自己已有会话时为 nil（任务的丢弃）。
    var sessions: [(task: UUID, step: UUID?)] = []
  }

  /// 离线并发的改动合并后可能违反层级规则；按确定的规则收敛，各设备算出同一结果：
  /// 挂在灵感下的（别处取消了要做）提到那个灵感的位置（挂到它的上级下）；环按 `CardHierarchy` 断（环里 id 最小的回到顶层）；
  /// 第 `maxTaskDepth + 1` 级的任务改挂到上级的上级；下级跟随上级的项目；
  /// 有步骤的任务下的提示词改挂到 `home(of:)`、记着的会话也交给它；一个叶子多条提示词的，按顺序并进第一条。
  ///
  /// 只查 `changed`（这次远端变更涉及的卡）、它们的全部子孙，以及它们的上级与上级的全部下级（步骤增减会改变这些下级的归属）：
  /// 层级规则只看一张卡自己、它的上级链和它的下级，这次没动过的卡，上级链上没有动过的就不会新违规（应用之前层级是成立的）。
  /// 整库一万张卡时，每次含卡片的远端批量应用不再整库重算。
  func repairs(touching changed: Set<UUID>) -> Repairs {
    var fixed = self
    let region = fixed.region(around: changed).sorted { $0.uuidString < $1.uuidString }
    while let stray = region.first(where: {
      fixed.links[$0]?.parent.flatMap { fixed.links[$0] }.map { !$0.isTask } ?? false
    }) {
      // 上级的上级就是它自己（挂在自己或绕回来的灵感下）：回到顶层，不然永远提不出去
      let grandparent = fixed.links[stray]?.parent.flatMap { fixed.links[$0]?.parent }
      fixed.relink(stray, parent: grandparent == stray ? nil : grandparent)
    }
    let untangled = CardHierarchy.breakingCycles(fixed.links.compactMapValues(\.parent), from: region)
    for (id, link) in fixed.links where link.parent != nil && untangled[id] == nil { fixed.relink(id, parent: nil) }
    while let deep = region.first(where: { fixed.links[$0]?.isTask == true && fixed.level(of: $0) > Card.maxTaskDepth }) {
      // 最浅的超限任务：它的上级在第 maxTaskDepth 级，改挂到上级的上级
      let chain = fixed.ancestors(of: deep)
      let shallowest = ([deep] + chain).last { fixed.level(of: $0) > Card.maxTaskDepth }!
      fixed.relink(shallowest, parent: fixed.links[shallowest]?.parent.flatMap { fixed.links[$0]?.parent })
    }
    var repairs = Repairs()
    fixed.settleHandoffs(in: region, &repairs)
    for id in region where fixed.links[id] != nil {
      guard let root = ([id] + fixed.ancestors(of: id)).last, root != id else { continue }
      let project = fixed.links[root]?.project
      fixed.links[id]?.project = project
    }
    repairs.links = Dictionary(uniqueKeysWithValues: region.compactMap { id in
      fixed.links[id].flatMap { $0 != links[id] ? (id, $0) : nil }
    })
    return repairs
  }

  /// 提示词与会话只在叶子上（见类型注释）：有步骤的任务把提示词与会话都交给 `home(of:)`；叶子上多条提示词并进第一条。
  /// `region` 里的任务与它们的上级各查一遍（步骤刚加上或挪走的上级就是这样被查到的）。
  private mutating func settleHandoffs(in region: [UUID], _ repairs: inout Repairs) {
    let tasks = Set(region.flatMap { id in [id, links[id]?.parent].compactMap(\.self) }).filter { links[$0]?.isTask == true }
    var kids: [UUID: [UUID]] = [:]
    for id in order {
      if let parent = links[id]?.parent, tasks.contains(parent) { kids[parent, default: []].append(id) }
    }
    func isDraft(_ id: UUID) -> Bool { links[id].map { !$0.isTask && !$0.isPinned } ?? false }
    var leaves: Set<UUID> = []
    for task in tasks.sorted(by: { $0.uuidString < $1.uuidString }) {
      let steps = (kids[task] ?? []).filter { links[$0]?.isTask == true }
      guard let home = Self.leaf(among: steps, links) else {
        leaves.insert(task)
        continue
      }
      for draft in kids[task] ?? [] where isDraft(draft) {
        relink(draft, parent: home)
        kids[home, default: []].append(draft)
      }
      if links[task]?.hasSession == true { repairs.sessions.append((task, links[home]?.hasSession == true ? nil : home)) }
      leaves.insert(home)
    }
    for leaf in leaves.sorted(by: { $0.uuidString < $1.uuidString }) {
      let drafts = (kids[leaf] ?? []).filter(isDraft).sorted { rank[$0, default: 0] < rank[$1, default: 0] }
      if drafts.count > 1 { repairs.merges[drafts[0]] = Array(drafts.dropFirst()) }
    }
  }

  /// 这些卡和它们的全部子孙（环里走到重复处为止），再加上它们的上级与上级的全部下级。已不在库里的卡（删了、进回收站）也算：它的下级成了顶层。
  private func region(around seeds: Set<UUID>) -> Set<UUID> {
    var seen = seeds, pending = Array(seeds)
    for seed in seeds {
      guard let parent = links[seed]?.parent, links[parent] != nil else { continue }
      for sibling in [parent] + (children[parent] ?? []) where seen.insert(sibling).inserted { pending.append(sibling) }
    }
    while let id = pending.popLast() {
      for child in children[id] ?? [] where seen.insert(child).inserted { pending.append(child) }
    }
    return seen
  }

  private mutating func relink(_ id: UUID, parent: UUID?) {
    links[id]?.parent = parent
  }
}
