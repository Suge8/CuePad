#if os(macOS)
import CueStore
import Foundation
import Testing

extension MCPTests {
  @Test func taskReferencesRespectProjectsAndDistinguishFinishingFromEnding() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let alpha = try await sandbox.project("甲")
    let beta = try await sandbox.project("乙")
    try await store.updateCueProfile { $0.hostID = "mac-a"; $0.enabledAt = .now }
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "free-session", state: .settled, title: "空闲会话", hosted: true)
    try await Server.run(library: sandbox.directory) { server in
      let first = try await server.call("task", ["action": "add", "title": "同名任务", "project": "甲"])
      let second = try await server.call("task", ["action": "add", "title": "同名任务", "project": "乙"])
      let cards = try await store.tasks(.todo).flatMap(\.tasks).filter { $0.heading == "同名任务" }
      let a = try #require(cards.first { $0.projectID == alpha.id })
      let b = try #require(cards.first { $0.projectID == beta.id })
      #expect(first.contains(a.id.shortID) && second.contains(b.id.shortID) && a.id != b.id)
      #expect(try await server.call("task", ["action": "add", "title": "同名任务", "project": "甲"]).contains(a.id.shortID))
      #expect(try await store.tasks(.todo).flatMap(\.tasks).filter { $0.heading == "同名任务" }.count == 2)
      #expect(try await server.refused("task", ["action": "done", "session": a.id.uuidString]).contains("做完任务给 task"))
      #expect(try await store.card(a.id)?.status == .todo)
      #expect(try await server.call("task", ["action": "done", "session": "free-session"]).contains("结束"))
      #expect(try await store.deliveryRequests().contains { $0.mode == .known(.end) && $0.target.ref == "free-session" })
      _ = try await server.call("task", ["action": "done", "task": a.id.uuidString, "evidence": ["完成"]])
      #expect(try await store.card(a.id)?.status == .done)
      #expect(try await store.card(b.id)?.status == .todo)
      #expect(try await server.refused("task", ["action": "unknown"]) == "task 没有 unknown：可用 add / edit / start / bind / unbind / say / peek / stop / leave / take / done")
    }
  }

  @Test func cueStopsLeavesAndTakesBackASession() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await store.updateCueProfile { $0.hostID = "mac-a"; $0.enabledAt = .now }
    let recorder = try await store.runtimeRecorder(on: "mac-a", boot: UUID().uuidString, minInterval: .zero)
    try await recorder.update(sessionID: "working-session", state: .thinking, title: "工作会话", hosted: true)
    try await Server.run(library: sandbox.directory) { server in
      #expect(try await server.call("task", ["action": "stop", "session": "working-session"]).contains("停下这一轮"))
      #expect(try await store.deliveryRequests().contains { $0.mode == .known(.stop) && $0.target.ref == "working-session" })
      try await recorder.update(sessionID: "working-session", state: .settled)
      #expect(try await server.call("task", ["action": "leave", "session": "working-session"]).contains("留给他回"))
      #expect(try await store.cueState()?.left.contains { $0.sessionID == "working-session" } == true)
      #expect(try await server.call("task", ["action": "take", "session": "working-session"]).contains("已收回"))
      #expect(try await store.cueState()?.left.isEmpty == true)
      #expect(try await server.refused("task", ["action": "take", "session": "working-session"]).contains("不用收回"))
    }
  }

  @Test func cueBindsExistingTaskWithoutSending() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let task = try await store.createTask("已有任务")
    try await store.setStatus(task.id, .inProgress)
    let started = try #require(try await store.card(task.id)?.startedAt)
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "session-one", state: .thinking, title: "已有会话", hosted: true)
    try await Server.run(library: sandbox.directory) { server in
      let args = ["action": "bind", "task": task.id.uuidString, "session": "session-one"]
      _ = try await server.call("task", args)
      _ = try await server.call("task", args)
      #expect(try await store.card(task.id)?.piSessionID == "session-one")
      #expect(try await store.card(task.id)?.startedAt == started)
      #expect(try await store.deliveryRequests().isEmpty)
      #expect(try await server.refused("task", ["action": "start", "task": task.id.uuidString, "session": "session-one"]).contains("session"))
      _ = try await server.refused("task", ["action": "bind", "task": task.id.uuidString, "session": "missing-session"])
      _ = try await server.refused("task", ["action": "unbind", "task": UUID().uuidString])
      _ = try await server.call("task", ["action": "unbind", "task": task.id.uuidString])
      #expect(try await store.card(task.id)?.piSessionID == nil)
      #expect(try await store.deliveryRequests().isEmpty)
    }
  }

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

      try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s9", state: .settled, projectID: project.id)
      try await store.bindSession("s9", to: step.id)
      #expect(try await server.refused("task", ["action": "start", "task": taskID]).contains("say"))
      #expect(try await store.deliveryRequests().count == 1)
    }
  }

  @Test func cueFinishesATopTaskAndReportsIt() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("修好登录页", in: project.id)
    let launch = try await store.requestLaunch(PiLaunch(project: project.id, prompt: task.body, token: "fix-login"), title: task.heading, on: "mac-a", card: task.id)
    try await PiStateRecorder(store: store, hostID: "mac-a").update(
      sessionID: "s1", state: .settled, title: "修好登录页", projectID: project.id, launchToken: launch.launch?.token, hosted: true)
    try await store.deleteDelivery(launch.id)
    try await Server.run(library: sandbox.directory) { server in
      try await server.refused("task", ["action": "done", "task": task.id.uuidString])
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
