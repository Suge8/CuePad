import Foundation
import Testing
@testable import CueStore

/// 层级收敛只查这次涉及的卡和它们的子孙，结果必须和整库收敛一模一样（各设备算出同一结果）：
/// 随机造一片合规的层级，再像远端批量应用那样改几张卡（改上级、项目、是不是任务，或删掉），两种算法比对。
@Suite(.timeLimit(.minutes(1))) struct CardLinksRepairTests {
  struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return Int((state >> 33) % UInt64(bound))
    }
  }

  private func validForest(_ random: inout Random) -> [(id: UUID, link: CardLinks.Link)] {
    let projects: [UUID?] = [nil, UUID(), UUID()]
    var rows: [(id: UUID, link: CardLinks.Link)] = []
    for _ in 0..<(8 + random.next(40)) {
      let id = UUID()
      let tasks = rows.filter { $0.link.isTask }
      let parent = tasks.isEmpty || random.next(3) == 0 ? nil : tasks[random.next(tasks.count)]
      if let parent {
        // 最多三级：上级的上级的上级之下不再挂
        var level = 1, cursor = parent.link.parent
        while let up = cursor { level += 1; cursor = rows.first { $0.id == up }?.link.parent }
        if level >= Card.maxDepth { rows.append((id, .init(parent: nil, project: projects[random.next(3)], isTask: random.next(2) == 0))); continue }
        rows.append((id, .init(parent: parent.id, project: parent.link.project, isTask: random.next(2) == 0)))
      } else {
        rows.append((id, .init(parent: nil, project: projects[random.next(3)], isTask: random.next(2) == 0)))
      }
    }
    return rows
  }

  @Test func repairingOnlyWhatABatchTouchedGivesTheSameResultAsRepairingEverything() {
    var random = Random(state: 20_261_011)
    var violating = 0
    for _ in 0..<400 {
      var rows = validForest(&random)
      let projects = Array(Set(rows.map(\.link.project))) + [UUID()]
      var touched: Set<UUID> = []
      for _ in 0..<(1 + random.next(3)) {
        let index = random.next(rows.count)
        let id = rows[index].id
        touched.insert(id)
        switch random.next(5) {
        case 0: rows[index].link.parent = rows[random.next(rows.count)].id  // 挂到任意一张卡下：环、挂在灵感下、超三级、跨项目
        case 1: rows[index].link.parent = nil
        case 2: rows[index].link.project = projects[random.next(projects.count)]
        case 3: rows[index].link.isTask.toggle()
        default: rows.remove(at: index)  // 删了或进回收站：下级的 parentID 还指着它
        }
      }
      let links = CardLinks(rows)
      let everything = links.repairs(touching: Set(links.links.keys).union(touched))
      if !everything.isEmpty { violating += 1 }
      #expect(links.repairs(touching: touched) == everything)
    }
    #expect(violating > 100)  // 随机改动确实常常造出违规，比对不是空转
  }
}
