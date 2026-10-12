import Foundation

/// 全部未删除卡片的层级关系（id → 上级、项目、是不是任务），一次读出，供远端变更后整库收敛（`repairs`）。
/// 上级不在（没到、在回收站）的按顶层看待。写入时的校验只问需要的几行，见 `CueStore+Tree`。
struct CardLinks {
  struct Link: Equatable {
    var parent: UUID?
    var project: UUID?
    var isTask: Bool
  }

  private(set) var links: [UUID: Link]
  private var children: [UUID: [UUID]] = [:]

  init(_ db: SQLite) throws {
    self.init(try db.query("SELECT id, parentID, projectID, todoAt IS NOT NULL FROM cards WHERE deletedAt IS NULL ORDER BY sortKey, id") {
      (id: $0.uuid(0), link: Link(parent: $0.uuidOrNil(1), project: $0.uuidOrNil(2), isTask: $0.bool(3)))
    })
  }

  /// 按同级顺序给出的卡片。
  init(_ rows: [(id: UUID, link: Link)]) {
    links = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.link) })
    for row in rows { if let parent = row.link.parent { children[parent, default: []].append(row.id) } }
  }

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
  /// 离线并发的改动合并后可能违反层级规则；按确定的规则收敛，各设备算出同一结果：
  /// 挂在灵感下的（别处取消了要做）提到那个灵感的位置（挂到它的上级下）；环里 id 最小的回到顶层；
  /// 第 `maxTaskDepth + 1` 级的任务改挂到上级的上级；挂在步骤下的提示词改挂到顶层任务下；下级跟随上级的项目。返回要改写的卡片。
  ///
  /// 只查 `changed`（这次远端变更涉及的卡）和它们的全部子孙：层级规则只看一张卡自己、它的上级链和它的下级，
  /// 这次没动过的卡，上级链上没有动过的就不会新违规（应用之前层级是成立的）。整库一万张卡时，每次含卡片的远端批量应用不再整库重算。
  func repairs(touching changed: Set<UUID>) -> [UUID: Link] {
    var fixed = self
    let region = fixed.region(around: changed).sorted { $0.uuidString < $1.uuidString }
    while let stray = region.first(where: {
      fixed.links[$0]?.parent.flatMap { fixed.links[$0] }.map { !$0.isTask } ?? false
    }) {
      // 上级的上级就是它自己（挂在自己或绕回来的灵感下）：回到顶层，不然永远提不出去
      let grandparent = fixed.links[stray]?.parent.flatMap { fixed.links[$0]?.parent }
      fixed.relink(stray, parent: grandparent == stray ? nil : grandparent)
    }
    while let cycle = fixed.firstCycle(from: region) {
      let breaker = cycle.min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }!
      fixed.relink(breaker, parent: nil)
    }
    while let deep = region.first(where: { fixed.links[$0]?.isTask == true && fixed.level(of: $0) > Card.maxTaskDepth }) {
      // 最浅的超限任务：它的上级在第 maxTaskDepth 级，改挂到上级的上级
      let chain = fixed.ancestors(of: deep)
      let shallowest = ([deep] + chain).last { fixed.level(of: $0) > Card.maxTaskDepth }!
      fixed.relink(shallowest, parent: fixed.links[shallowest]?.parent.flatMap { fixed.links[$0]?.parent })
    }
    while let prompt = region.first(where: { id in
      guard let link = fixed.links[id], !link.isTask, let parent = link.parent, fixed.links[parent] != nil else { return false }
      return fixed.level(of: parent) > 1
    }) {
      fixed.relink(prompt, parent: fixed.ancestors(of: prompt).last)
    }
    for id in region where fixed.links[id] != nil {
      guard let root = ([id] + fixed.ancestors(of: id)).last, root != id else { continue }
      let project = fixed.links[root]?.project
      fixed.links[id]?.project = project
    }
    return Dictionary(uniqueKeysWithValues: region.compactMap { id in
      fixed.links[id].flatMap { $0 != links[id] ? (id, $0) : nil }
    })
  }

  /// 这些卡和它们的全部子孙（环里走到重复处为止）。已不在库里的卡（删了、进回收站）也算：它的下级成了顶层。
  private func region(around seeds: Set<UUID>) -> Set<UUID> {
    var seen = seeds, pending = Array(seeds)
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
