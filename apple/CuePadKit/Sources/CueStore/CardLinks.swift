import Foundation

struct CardLinks {
  struct Link: Equatable {
    var parent: UUID?
    var project: UUID
    var isTask: Bool
    var isDone = false
    var hasSession = false
  }

  private static let columns =
    "id, parentID, projectID, todoAt IS NOT NULL, completedAt IS NOT NULL, piSessionID IS NOT NULL"

  private(set) var links: [UUID: Link]
  private var order: [UUID]
  private var children: [UUID: [UUID]] = [:]

  init(_ db: SQLite) throws {
    self.init(try db.query("SELECT \(Self.columns) FROM cards WHERE deletedAt IS NULL ORDER BY sortKey, id", [], Self.row))
  }

  init(_ db: SQLite, around tasks: [UUID]) throws {
    let marks = "SELECT value FROM json_each(?1)"
    self.init(
      try db.query(
        """
        SELECT \(Self.columns) FROM cards WHERE deletedAt IS NULL AND (id IN (\(marks)) OR parentID IN (\(marks))
          OR parentID IN (SELECT id FROM cards WHERE parentID IN (\(marks)))) ORDER BY sortKey, id
        """, [CueStore.idList(tasks)], Self.row))
  }

  private static func row(_ row: Row) -> (id: UUID, link: Link) {
    (
      row.uuid(0),
      Link(
        parent: row.uuidOrNil(1), project: row.uuid(2), isTask: row.bool(3), isDone: row.bool(4), hasSession: row.bool(5))
    )
  }

  init(_ rows: [(id: UUID, link: Link)]) {
    links = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.link) })
    order = rows.map(\.id)
    for row in rows { if let parent = row.link.parent { children[parent, default: []].append(row.id) } }
  }

  private func steps(of task: UUID) -> [UUID] { (children[task] ?? []).filter { links[$0]?.isTask == true } }

  func home(of task: UUID) -> UUID { Self.leaf(among: steps(of: task), links) ?? task }

  private static func leaf(among steps: [UUID], _ links: [UUID: Link]) -> UUID? { steps.first { links[$0]?.isDone == false } ?? steps.first }

  func ancestors(of id: UUID) -> [UUID] {
    var chain: [UUID] = [], cursor = links[id]?.parent
    while let parent = cursor, links[parent] != nil, parent != id, !chain.contains(parent) {
      chain.append(parent)
      cursor = links[parent]?.parent
    }
    return chain
  }

  func level(of id: UUID) -> Int { ancestors(of: id).count + 1 }
}

extension CardLinks {
  struct Repairs {
    var links: [UUID: Link] = [:]
    var handoffs: [(task: UUID, step: UUID?)] = []
  }

  func repairs(touching changed: Set<UUID>) -> Repairs {
    var fixed = self
    let region = fixed.region(around: changed).sorted { $0.uuidString < $1.uuidString }
    while let stray = region.first(where: {
      fixed.links[$0]?.parent.flatMap { fixed.links[$0] }.map { !$0.isTask } ?? false
    }) {
      let grandparent = fixed.links[stray]?.parent.flatMap { fixed.links[$0]?.parent }
      fixed.relink(stray, parent: grandparent == stray ? nil : grandparent)
    }
    while let cycle = fixed.firstCycle(from: region) {
      let breaker = cycle.min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }!
      fixed.relink(breaker, parent: nil)
    }
    while let deep = region.first(where: { fixed.links[$0]?.isTask == true && fixed.level(of: $0) > Card.maxTaskDepth }) {
      let chain = fixed.ancestors(of: deep)
      let shallowest = ([deep] + chain).last { fixed.level(of: $0) > Card.maxTaskDepth }!
      fixed.relink(shallowest, parent: fixed.links[shallowest]?.parent.flatMap { fixed.links[$0]?.parent })
    }
    var repairs = Repairs()
    fixed.settleHandoffs(in: region, &repairs)
    for id in region where fixed.links[id] != nil {
      guard let root = ([id] + fixed.ancestors(of: id)).last, root != id, let project = fixed.links[root]?.project else { continue }
      fixed.links[id]?.project = project
    }
    repairs.links = Dictionary(uniqueKeysWithValues: region.compactMap { id in
      fixed.links[id].flatMap { $0 != links[id] ? (id, $0) : nil }
    })
    return repairs
  }

  private mutating func settleHandoffs(in region: [UUID], _ repairs: inout Repairs) {
    let tasks = Set(region.flatMap { id in [id, links[id]?.parent].compactMap(\.self) }).filter { links[$0]?.isTask == true }
    var steps: [UUID: [UUID]] = [:]
    for id in order {
      if let parent = links[id]?.parent, tasks.contains(parent), links[id]?.isTask == true { steps[parent, default: []].append(id) }
    }
    for task in tasks.sorted(by: { $0.uuidString < $1.uuidString }) where links[task].map({ $0.hasSession }) == true {
      guard let home = Self.leaf(among: steps[task] ?? [], links) else { continue }
      repairs.handoffs.append((task, links[home]?.hasSession == true ? nil : home))
    }
  }

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

  private func firstCycle(from starts: [UUID]) -> [UUID]? {
    for start in starts where links[start] != nil {
      var path: [UUID] = [start], cursor = links[start]?.parent
      while let parent = cursor, links[parent] != nil {
        if let index = path.firstIndex(of: parent) { return Array(path[index...]) }
        path.append(parent)
        cursor = links[parent]?.parent
      }
    }
    return nil
  }

  private mutating func relink(_ id: UUID, parent: UUID?) {
    links[id]?.parent = parent
  }
}
