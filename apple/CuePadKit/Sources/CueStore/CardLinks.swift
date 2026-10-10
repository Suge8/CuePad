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

  init(_ db: SQLite) throws {
    links = Dictionary(
      uniqueKeysWithValues: try db.query("SELECT id, parentID, projectID, todoAt IS NOT NULL FROM cards WHERE deletedAt IS NULL") {
        ($0.uuid(0), Link(parent: $0.uuidOrNil(1), project: $0.uuidOrNil(2), isTask: $0.bool(3)))
      })
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
    links[id]?.parent = parent
  }
}
