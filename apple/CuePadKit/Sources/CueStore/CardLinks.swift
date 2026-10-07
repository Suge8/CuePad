import Foundation

/// 全部未删除卡片的层级关系（id → 上级、项目、是不是任务），一次读出，供写入时校验与远端变更后收敛。
/// 上级不在（没到、在回收站）的按顶层看待。
struct CardLinks {
  struct Link: Equatable {
    var parent: UUID?
    var project: UUID?
    var isTask: Bool
  }

  private(set) var links: [UUID: Link]
  private var children: [UUID: [UUID]] = [:]

  init(_ db: SQLite) throws {
    let rows = try db.query("SELECT id, parentID, projectID, todoAt IS NOT NULL FROM cards WHERE deletedAt IS NULL ORDER BY sortKey, id") {
      (id: $0.uuid(0), link: Link(parent: $0.uuidOrNil(1), project: $0.uuidOrNil(2), isTask: $0.bool(3)))
    }
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

  /// 第几级：顶层是 1。
  func level(of id: UUID) -> Int { ancestors(of: id).count + 1 }

  /// 连自己在内往下有几级。
  func height(of id: UUID) -> Int { 1 + ((children[id] ?? []).map(height(of:)).max() ?? 0) }

  /// 全部子孙，先序。
  func descendants(of id: UUID) -> [UUID] {
    (children[id] ?? []).flatMap { [$0] + descendants(of: $0) }
  }
}

extension CardLinks {
  /// 离线并发的改动合并后可能违反层级规则；按确定的规则收敛，各设备算出同一结果：
  /// 挂在灵感下的（别处取消了要做）提到那个灵感的位置（挂到它的上级下）；环里 id 最小的回到顶层；
  /// 挂在第 `maxDepth` 级下的改挂到第 `maxDepth - 1` 级上；下级跟随上级的项目。返回要改写的卡片。
  func repairs() -> [UUID: Link] {
    var fixed = self
    while let stray = fixed.links.keys.sorted(by: { $0.uuidString < $1.uuidString }).first(where: {
      fixed.links[$0]?.parent.flatMap { fixed.links[$0] }.map { !$0.isTask } ?? false
    }) {
      fixed.relink(stray, parent: fixed.links[stray]?.parent.flatMap { fixed.links[$0]?.parent })
    }
    while let cycle = fixed.firstCycle() {
      let breaker = cycle.min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }!
      fixed.relink(breaker, parent: nil)
    }
    while let deep = fixed.links.keys.sorted(by: { $0.uuidString < $1.uuidString }).first(where: { fixed.level(of: $0) > Card.maxDepth }) {
      // 最浅的超限者：它的上级在第 maxDepth 级，改挂到上级的上级
      let chain = fixed.ancestors(of: deep)
      let shallowest = ([deep] + chain).last { fixed.level(of: $0) > Card.maxDepth }!
      fixed.relink(shallowest, parent: fixed.links[shallowest]?.parent.flatMap { fixed.links[$0]?.parent })
    }
    for id in fixed.links.keys {
      guard let root = ([id] + fixed.ancestors(of: id)).last, root != id else { continue }
      let project = fixed.links[root]?.project
      fixed.links[id]?.project = project
    }
    return fixed.links.filter { links[$0.key] != $0.value }
  }

  private func firstCycle() -> [UUID]? {
    for start in links.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
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
    if let old = links[id]?.parent { children[old]?.removeAll { $0 == id } }
    links[id]?.parent = parent
    if let parent { children[parent, default: []].append(id) }
  }
}
