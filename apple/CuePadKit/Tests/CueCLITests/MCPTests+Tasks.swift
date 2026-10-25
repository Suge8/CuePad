#if os(macOS)
import CueStore
import Foundation
import Testing

extension MCPTests {
  /// 没给项目建的任务落在默认项目：Cue 用 edit 的 project 把它连同子任务与草稿挪进别的项目，开工就在那个项目的文件夹。
  @Test func cueMovesATaskFromTheDefaultProjectIntoAnother() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("greet")
    try await store.setDirectory("/tmp/greet", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    try await store.recordMacAgents(host: "mac-a", name: nil, [MacAgent(kind: .pi, model: nil, models: [])])
    try await Server.run(library: sandbox.directory) { server in
      try await server.call("task", ["action": "add", "title": "加问候语", "steps": ["写文案"], "body": "先看现有问候"])
      let task = try #require(try await store.tasks(.todo).flatMap(\.tasks).first { $0.heading == "加问候语" }).id
      let taskID = task.uuidString
      let step = try #require(try await store.children(of: task).first)
      #expect(try await store.card(task)?.projectID == Project.defaultID)
      #expect(try await store.card(task)?.body == "加问候语\n先看现有问候")

      _ = try await server.call("task", ["action": "edit", "task": taskID, "project": "greet"])
      for id in [task, step.id] { #expect(try await store.card(id)?.projectID == project.id) }
      _ = try await server.call("task", ["action": "start", "task": taskID])
      #expect(try await store.deliveryRequests().first?.launch?.project == project.id)

      // 你亲手给子任务绑上会话：再开工被拒（叫它用 say），什么请求都不多写
      try await store.bindSession("s9", to: step.id)
      #expect(try await server.refused("task", ["action": "start", "task": taskID]).contains("say"))
      #expect(try await store.deliveryRequests().count == 1)
    }
  }

  /// 会话交了结果、Cue 收尾（task done 带证据）：Cue 自己验收，顶层任务直接完成，不请用户收下；做完了的会话请它结束（算 Cue 发起），
  /// 给用户写一条结果（关联任务、不是"等你"，正文由代码拼成"「任务名」做完了"加证据要点）。再调一次只说已经完成，不重复写。
  /// 整件事收尾要带证据：没带、多于 3 条或一条太长都退回，什么都不写。
  @Test func cueFinishesATopTaskAndReportsIt() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("修好登录页", in: project.id)
    try await store.linkCard(task.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, title: "修好登录页")
    try await Server.run(library: sandbox.directory) { server in
      try await server.refused("task", ["action": "done", "task": task.id.uuidString])
      // 证据多于 3 条或一条太长：退回，什么都不写
      for bad in [["一", "二", "三", "四"], ["登录测试 12 个全过，另外把注册页、找回密码页也顺手都改好了"]] {
        try await server.refused("task", ["action": "done", "task": task.id.uuidString, "evidence": bad])
      }
      #expect(try await store.card(task.id)?.status != .done)
      #expect(try await store.cueMessages().isEmpty)

      let evidence = ["登录测试 12 个全过", "截图里错误提示对上了"]
      for _ in 0..<2 { _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": evidence]) }
      #expect(try await store.card(task.id)?.status == .done)
      #expect(try await store.cueMessagesWaitingForYou().isEmpty)
      let reports = try await store.cueMessages().filter { $0.author == .known(.cue) }
      #expect(reports.count == 1)
      let report = try #require(reports.first)
      #expect(report.choices == nil && report.taskID == task.id)
      #expect(report.text == "「修好登录页」做完了\n\n- 登录测试 12 个全过\n- 截图里错误提示对上了")
      let ends = try await store.deliveryRequests().filter { $0.mode == .known(.end) }
      #expect(ends.compactMap(\.target.ref) == ["s1"] && ends.allSatisfy { $0.isFromCue && $0.hostID == "mac-a" })
    }
  }
}
#endif
