#if os(macOS)
import CueStore
import Foundation
import Testing

extension MCPTests {
  @Test func cueStartsASessionWithTheAgentItChose() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("修好登录页\n登录页白屏，查一下", in: project.id)
    try await store.recordMacAgents(
      host: "mac-a", name: nil, [AgentKind.claudeCode, .codex].map { MacAgent(kind: $0, model: nil, models: []) },
      problems: [MacAgentProblem(kind: .pi, reason: .notLoggedIn)])
    try await Server.run(library: sandbox.directory) { server in
      for bad in [["agent": "pi"], ["agent": "opencode", "model": "big-pickle"], ["agent": "cursor"]] {
        try await server.refused("task", ["action": "start", "task": task.id.uuidString].merging(bad) { $1 })
      }
      #expect(try await server.refused("task", ["action": "start", "task": task.id.uuidString, "agent": "pi"]).contains("Pi 没登录"))
      #expect(try await store.deliveryRequests().isEmpty)

      let other = try await store.createTask("改文案", in: project.id)
      try await server.call("task", ["action": "start", "task": other.id.uuidString, "model": "sonnet"])
      let byDefault = try #require(try await store.deliveryRequests().first)
      #expect(byDefault.launch?.agent == .claudeCode && byDefault.launch?.model == ModelKey(provider: "claude", id: "sonnet"))

      let since = CueMarks(try await store.lastWrite())
      _ = try await server.call("task", ["action": "start", "task": task.id.uuidString, "agent": "codex", "model": "gpt-5.1", "effort": "high"])
      let launch = try #require(try await store.deliveryRequests().first { $0.cardID == task.id })
      #expect(launch.isFromCue && launch.mode == .known(.start))
      #expect(launch.launch?.agent == .codex && launch.launch?.model == ModelKey(provider: "codex", id: "gpt-5.1") && launch.launch?.thinking == .high)

      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { request, _ in
        request.launch?.agent == .codex ? .failed(.verbatim("这台 Mac 上没有找到 Codex")) : .succeeded
      }
      try await executor.start()
      defer { Task { await executor.stop() } }
      let changes = try await eventually(store, { try $0.cueChanges(after: since).due }) { !$0.isEmpty }
      #expect(changes.map(\.kind) == [.failed] && changes.map(\.detail) == ["开工：这台 Mac 上没有找到 Codex"])
      #expect(changes.first?.task?.id == task.id)
    }
  }

  @Test func cueSwitchesTheSessionModelBeforeSpeaking() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    try await store.recordMacPresence(host: "mac-a") { true }  // 会话所在的 Mac 醒着：它上面的会话才算在跑，Cue 才能对它说话
    let recorder = StateRecorder(store: store, hostID: "mac-a")
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    let pi = try await store.createTask("修好登录页"), claude = try await store.createTask("改文案", in: project.id)
    try await store.linkCard(pi.id, toSession: "s1")
    try await store.linkCard(claude.id, toSession: "c1")
    try await recorder.update(sessionID: "s1", state: .error, title: "修好登录页")
    try await recorder.update(sessionID: "c1", state: .error, title: "改文案", agent: .claudeCode)
    try await Server.run(library: sandbox.directory) { server in
      // 这台 Mac 一收到就办成：说话、作答的工具等得到结果，马上返回
      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
      try await executor.start()
      defer { Task { await executor.stop() } }

      _ = try await server.call(
        "task", ["action": "say", "task": pi.id.uuidString, "text": "用 luna 重试", "model": "openai/gpt-6-luna", "effort": "high"])
      let requests = try await store.deliveryRequests(toSession: "s1")  // 执行器按这个先后执行
      #expect(requests.map(\.mode) == [.known(.config), .known(.send)] && requests.allSatisfy(\.isFromCue))
      #expect(requests.first?.config == SessionConfig(model: ModelKey(provider: "openai", id: "gpt-6-luna"), thinking: .high))
      #expect(requests.last?.content == "用 luna 重试")

      let reason = try await server.refused("task", ["action": "say", "task": claude.id.uuidString, "text": "换个模型", "model": "opus"])
      #expect(reason.contains("换不了模型") && reason.contains("fresh"))
      #expect(try await store.deliveryRequests().count == 2)

      let question = Question(promptID: "p", kind: .confirm, text: "继续？")
      try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
      try await recorder.update(sessionID: "c1", state: .waitingForUser, question: question, agent: .claudeCode)
      let answer = ["action": "say", "task": pi.id.uuidString, "model": "openai/gpt-6-sol", "effort": "low"]
      try await server.refused("task", answer.merging(["text": "也许"]) { $1 })
      #expect(try await store.deliveryRequests().count == 2)
      #expect(try await server.refused("task", ["action": "say", "task": claude.id.uuidString, "text": "yes", "model": "opus"]).contains("换不了模型"))
      #expect(try await store.deliveryRequests().count == 2)
      _ = try await server.call("task", answer.merging(["text": "yes"]) { $1 })
      let answered = try await store.deliveryRequests(toSession: "s1").suffix(2)
      #expect(answered.map(\.mode) == [.known(.config), .known(.answer)] && answered.allSatisfy(\.isFromCue))
      #expect(answered.first?.config == SessionConfig(model: ModelKey(provider: "openai", id: "gpt-6-sol"), thinking: .low))

      _ = try await server.call("task", ["action": "start", "task": claude.id.uuidString, "agent": "claude", "model": "opus", "fresh": true])
      let launch = try #require(try await store.deliveryRequests().first { $0.mode == .known(.start) })
      #expect(launch.launch?.agent == .claudeCode && launch.launch?.model == ModelKey(provider: "claude", id: "opus"))
      // 换下来的是终端里他自己开的会话：不替他结束（结束就是关掉他的终端进程）
      #expect(try await store.deliveryRequests(toSession: "c1").allSatisfy { $0.mode != .known(.end) })
    }
  }
}
#endif
