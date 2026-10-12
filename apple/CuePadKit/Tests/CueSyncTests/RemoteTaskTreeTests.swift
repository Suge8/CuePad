import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 远端变更下的任务层级不变量：两台设备离线并发地挪任务，合并后可能出现环、任务超过两级、步骤与父任务不在同一项目。
/// 应用远端变更后按确定的规则收敛（各设备算出同一结果），修正写回并推送：
/// 环里 id 最小的那条回到顶层；第三级的任务提到第二级（挂到上级的上级下）；步骤下的提示词改挂到顶层任务；步骤跟随父任务的项目。
/// 父任务还没到（乱序）的不动。
@Suite struct RemoteTaskTreeTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  private func remote(_ task: Card, parent: UUID?, project: UUID? = nil, later: Int64 = 1_000) -> CKRecord {
    var fields = cardFields(project: project ?? task.projectID, body: task.body, modifiedAt: millis(task.modifiedAt) + later, sortKey: task.sortKey)
    fields["parentID"] = parent.map { .text($0.uuidString.lowercased()) } ?? .null
    fields["todoAt"] = .int(1_000)
    return remoteRecord(.cards, id: task.id, fields)
  }

  private func pushed() async throws {
    try await rig.coordinator.reconcile()
    try await rig.simulatePush()
  }

  @Test func 两台设备互相挂成环_环里id最小的回到顶层_修正被推送() async throws {
    let a = try await store.createTask("a", in: nil)
    let b = try await store.createTask("b", in: nil)
    try await pushed()
    try await store.moveCard(a.id, to: .under(b.id), after: nil)
    let movedB = try #require(try await store.card(b.id))

    await rig.coordinator.handle(.fetched(modifications: [remote(movedB, parent: a.id)], deletions: []))

    let first = [a.id, b.id].min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }!
    let other = first == a.id ? b.id : a.id
    #expect(try await store.card(first)?.parentID == nil)
    #expect(try await store.card(other)?.parentID == first)
    #expect(try await rig.reconcileDelta().saves.contains(rig.id(first)))
  }

  private struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return Int((state >> 33) % UInt64(bound))
    }
  }

  /// 随机造一片合规的层级，再像远端批量应用那样改几张卡（改上级——含挂到自己、后代、灵感下——、项目、是不是任务，或删掉），
  /// 应用后用户读到的层级必须满足规则：上级是任务、与下级同项目、不成环、任务最多两级。
  @Test(.timeLimit(.minutes(1)))
  func 随机的远端批量改动之后_层级总是合规() async throws {
    var random = Random(state: 20_261_011)
    for round in 0..<60 {
      let rig = try Rig()
      let store = rig.store
      let projects = [try await store.createProject(name: "甲", color: "#111").id, try await store.createProject(name: "乙", color: "#111").id]
      var made: [(id: UUID, isTask: Bool, depth: Int)] = []
      for index in 0..<(8 + random.next(25)) {
        let project: UUID? = random.next(3) == 0 ? nil : projects[random.next(2)]
        let parents = made.filter { $0.isTask && $0.depth < 2 }
        let parent = parents.isEmpty || random.next(3) == 0 ? nil : parents[random.next(parents.count)]
        let isTask = random.next(2) == 0
        let card: Card
        switch (isTask, parent) {
        case (true, let parent?): card = try await store.createTask("t\(index)", under: parent.id)
        case (true, nil): card = try await store.createTask("t\(index)", in: project)
        case (false, let parent?): card = try await store.createCard(body: "i\(index)", under: parent.id)
        case (false, nil): card = try await store.createCard(in: project, body: "i\(index)")
        }
        made.append((card.id, isTask, (parent?.depth ?? 0) + 1))
      }
      try await rig.coordinator.reconcile()
      try await rig.simulatePush()

      var changes: [CKRecord] = []
      var deletions: [(id: CKRecord.ID, recordType: String)] = []
      for pick in Set((0..<(1 + random.next(3))).map { _ in random.next(made.count) }) {
        let current = try #require(try await store.card(made[pick].id))
        var parent = current.parentID, project = current.projectID, isTask = current.isTask
        switch random.next(5) {
        case 0: parent = made[random.next(made.count)].id
        case 1: parent = nil
        case 2: let choices: [UUID?] = [nil, projects[0], projects[1]]; project = choices[random.next(3)]
        case 3: isTask.toggle()
        default:
          deletions.append((rig.recordID(current.id), Table.cards.rawValue))
          continue
        }
        var fields = cardFields(project: project, body: current.body, modifiedAt: millis(current.modifiedAt) + 1_000, sortKey: current.sortKey)
        fields["parentID"] = parent.map { .text($0.uuidString.lowercased()) } ?? .null
        fields["todoAt"] = isTask ? .int(1_000) : .null
        changes.append(remoteRecord(.cards, id: current.id, fields))
      }

      await rig.coordinator.handle(.fetched(modifications: changes, deletions: deletions))

      for item in made {
        guard let card = try await store.card(item.id), card.deletedAt == nil else { continue }
        if let parentID = card.parentID, let parent = try await store.card(parentID), parent.deletedAt == nil {
          #expect(parent.isTask && parent.projectID == card.projectID, "第 \(round) 轮：上级须是任务且同项目")
        }
        var depth = 1, cursor = card.parentID
        while let up = cursor, let next = try await store.card(up), next.deletedAt == nil, depth <= 4 {
          depth += 1
          cursor = next.parentID
        }
        #expect(!card.isTask || depth <= 2, "第 \(round) 轮：成环或任务超过两级")
      }
    }
  }

  @Test func 并发挪出第三级任务_提到第二级_叶子的提示词跟着() async throws {
    let a = try await store.createTask("a", in: nil)
    let a1 = try await store.createTask("a1", under: a.id)
    let b = try await store.createTask("b", in: nil)
    let b1 = try await store.createTask("b1", under: b.id)
    let note = try await store.createCard(body: "备注", under: b1.id)
    try await pushed()

    await rig.coordinator.handle(.fetched(modifications: [remote(b, parent: a1.id)], deletions: []))

    #expect(try await store.card(b.id)?.parentID == a.id)
    #expect(try await store.card(b1.id)?.parentID == a.id)
    #expect(try await store.card(note.id)?.parentID == b1.id)  // b1 是步骤也是叶子：草稿留在它下面
  }

  @Test func 提示词与会话只在叶子上_远端让叶子有了步骤_草稿落到第一个没完成的步骤并成一条_会话交给第一个步骤() async throws {
    let top = try await store.createTask("上线", in: nil)
    let first = try await store.createTask("备份", in: nil)
    let second = try await store.createTask("发布", in: nil)
    let later = try await store.createCard(in: nil, body: "第二条")
    let earlier = try await store.createCard(in: nil, body: "第一条")  // 新灵感排在最前：排序键更小
    try await store.linkCard(top.id, toSession: "s1")
    try await store.linkCard(second.id, toSession: "s2")
    try await pushed()

    func record(_ card: Card, parent: UUID, sortKey: String, task: Bool = true, done: Bool = false, session: String? = nil) -> CKRecord {
      var fields = cardFields(project: nil, body: card.body, modifiedAt: millis(card.modifiedAt) + 1_000, sortKey: sortKey)
      fields["parentID"] = .text(parent.uuidString.lowercased())
      fields["todoAt"] = task ? .int(1_000) : .null
      fields["completedAt"] = done ? .int(3_000) : .null
      fields["piSessionID"] = session.map { .text($0) } ?? .null
      return remoteRecord(.cards, id: card.id, fields)
    }
    // 另一台设备给"上线"加了两个步骤（备份已完成），又把两条灵感挂在"上线"下
    let changes = [
      record(first, parent: top.id, sortKey: "a", done: true), record(second, parent: top.id, sortKey: "b", session: "s2"),
      record(later, parent: top.id, sortKey: "c", task: false), record(earlier, parent: top.id, sortKey: "b", task: false),
    ]
    await rig.coordinator.handle(.fetched(modifications: changes, deletions: []))

    let drafts = try await store.children(of: second.id).filter { !$0.isTask }
    #expect(drafts.map(\.id) == [earlier.id] && drafts[0].body == "第一条\n\n第二条")
    #expect(try await store.card(later.id) == nil)
    #expect(try await store.children(of: top.id).filter { !$0.isTask }.isEmpty)
    #expect(try await store.card(top.id)?.piSessionID == nil)
    #expect(try await store.card(first.id)?.piSessionID == "s1")
    #expect(try await store.card(second.id)?.piSessionID == "s2")
  }

  @Test func 父任务在别处换了项目_步骤跟过去_父任务还没到的不动() async throws {
    let site = try await store.createProject(name: "网站", color: "#111")
    let table = try await store.createProject(name: "圆桌", color: "#111")
    let parent = try await store.createTask("上线", in: site.id)
    let child = try await store.createTask("备份", under: parent.id)
    try await pushed()

    var fields = cardFields(project: nil, body: "父任务还在路上", modifiedAt: 2_000)
    fields["parentID"] = .text(UUID().uuidString.lowercased())
    fields["todoAt"] = .int(1_000)
    let orphan = remoteRecord(.cards, fields)
    await rig.coordinator.handle(.fetched(modifications: [remote(parent, parent: nil, project: table.id), orphan], deletions: []))

    #expect(try await store.card(child.id)?.projectID == table.id)
    let waiting = try #require(try await store.tasks(.todo).flatMap(\.tasks).first { $0.body == "父任务还在路上" })
    #expect(waiting.parentID != nil)
  }
}
