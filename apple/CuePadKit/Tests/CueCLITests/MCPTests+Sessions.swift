#if os(macOS)
import CueStore
import Foundation
import Testing

extension MCPTests {
  /// Cue 派活时选哪家 Agent 开会话：请求带着这家与模型（写法同给大脑的清单：Claude Code、Codex 只写 id，提供方补成这家；
  /// Pi、OpenCode 要写 provider/id）。不写 agent 用那台 Mac 的默认（能用的第一家）；写了那台 Mac 记着不能用的那家，当场退回并说原因。
  /// 那台 Mac 开不了这家时，失败是这件事的一条变化（还没开成会话也报），写着"开工：原因"，Cue 下次醒来看得到。
  @Test(.timeLimit(.minutes(1))) func cueStartsASessionWithTheAgentItChose() async throws {
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
      #expect(byDefault.launch?.agent == .claudeCode && byDefault.launch?.model == PiModelKey(provider: "claude", id: "sonnet"))

      let since = CueMarks(try await store.lastWrite())
      _ = try await server.call("task", ["action": "start", "task": task.id.uuidString, "agent": "codex", "model": "gpt-5.1", "effort": "high"])
      let launch = try #require(try await store.deliveryRequests().first { $0.cardID == task.id })
      #expect(launch.isFromCue && launch.mode == .known(.start))
      #expect(launch.launch?.agent == .codex && launch.launch?.model == PiModelKey(provider: "codex", id: "gpt-5.1") && launch.launch?.thinking == .high)

      // 那台 Mac 上没有 Codex：执行器把失败写回
      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) {
        $0.launch?.agent == .codex ? .failed(.verbatim("这台 Mac 上没有找到 Codex")) : .succeeded
      }
      try await executor.start()
      defer { Task { await executor.stop() } }
      let changes = try await eventually(store, { try $0.cueChanges(after: since).due }) { !$0.isEmpty }
      #expect(changes.map(\.kind) == [.failed] && changes.map(\.detail) == ["开工：这台 Mac 上没有找到 Codex"])
      #expect(changes.first?.task?.id == task.id)
    }
  }

  /// 会话因为模型出错，你让换个模型：Cue 的 say 带 model、effort，先请会话换模型（与界面换模型同一种请求），再说这句；
  /// 换不了模型的会话（终端里的 Claude Code）直接报错，什么都不写，告诉 Cue 可以 fresh 开新会话。
  @Test(.timeLimit(.minutes(1))) func cueSwitchesTheSessionModelBeforeSpeaking() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    let pi = try await store.createTask("修好登录页"), claude = try await store.createTask("改文案", in: project.id)
    try await store.linkCard(pi.id, toSession: "s1")
    try await store.linkCard(claude.id, toSession: "c1")
    try await recorder.update(sessionID: "s1", state: .error, title: "修好登录页")
    try await recorder.update(sessionID: "c1", state: .error, title: "改文案", agent: .claudeCode)
    try await Server.run(library: sandbox.directory) { server in
      // 这台 Mac 一收到就办成：说话、作答的工具等得到结果，马上返回
      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _ in .succeeded }
      try await executor.start()
      defer { Task { await executor.stop() } }

      _ = try await server.call(
        "task", ["action": "say", "task": pi.id.uuidString, "text": "用 luna 重试", "model": "openai/gpt-6-luna", "effort": "high"])
      let requests = try await store.deliveryRequests(toSession: "s1")  // 执行器按这个先后执行
      #expect(requests.map(\.mode) == [.known(.config), .known(.send)] && requests.allSatisfy(\.isFromCue))
      #expect(requests.first?.config == PiConfig(model: PiModelKey(provider: "openai", id: "gpt-6-luna"), thinking: .high))
      #expect(requests.last?.content == "用 luna 重试")

      let reason = try await server.refused("task", ["action": "say", "task": claude.id.uuidString, "text": "换个模型", "model": "opus"])
      #expect(reason.contains("换不了模型") && reason.contains("fresh"))
      #expect(try await store.deliveryRequests().count == 2)

      // 会话在等提问时说的话就是答案：同样先换模型再答；答案无效时什么都不写，换不了模型的会话报错
      let question = PiQuestion(promptID: "p", kind: .confirm, text: "继续？")
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
      #expect(answered.first?.config == PiConfig(model: PiModelKey(provider: "openai", id: "gpt-6-sol"), thinking: .low))

      // 照提示 fresh 开新会话：绑着会话的叶子也开新的
      _ = try await server.call("task", ["action": "start", "task": claude.id.uuidString, "agent": "claude", "model": "opus", "fresh": true])
      let launch = try #require(try await store.deliveryRequests().first { $0.mode == .known(.start) })
      #expect(launch.launch?.agent == .claudeCode && launch.launch?.model == PiModelKey(provider: "claude", id: "opus"))
      #expect(try await store.deliveryRequests(toSession: "c1").last?.mode == .known(.end))  // 换下来的会话结束
    }
  }
}
#endif
