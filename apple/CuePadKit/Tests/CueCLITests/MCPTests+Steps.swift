#if os(macOS)
import CueStore
import Foundation
import Testing

extension MCPTests {
  @Test func stepsOfATaskContinueInTheSameSession() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("重写发布脚本", in: project.id)
    let first = try await store.createTask("调研", under: task.id), second = try await store.createTask("改脚本", under: task.id)
    let opening = try await store.requestLaunch(LaunchRequest(project: project.id, prompt: first.body, token: "first-step"), title: first.heading, on: "mac-a", card: first.id)
    try await store.recordMacPresence(host: "mac-a") { true }  // 会话所在的 Mac 醒着：下一步才能接着用它的会话
    try await StateRecorder(store: store, hostID: "mac-a").update(
      sessionID: "s1", state: .settled, title: "调研", projectID: project.id, launchToken: opening.launch?.token, hosted: true)
    try await store.deleteDelivery(opening.id)
    try await Server.run(library: sandbox.directory) { server in
      _ = try await server.call("task", ["action": "done", "task": first.id.uuidString, "evidence": ["看完了"]])
      #expect(try await store.card(first.id)?.status == .done)
      #expect(try await store.deliveryRequests().isEmpty)

      try await store.updateCard(second.id) { $0.body += "\n照调研结论改 release.sh" }
      async let started = server.call("task", ["action": "start", "task": second.id.uuidString])
      let sent = try await eventually(store, { try $0.deliveryRequests() }) { !$0.isEmpty }
      #expect(sent.map(\.mode) == [.known(.send)] && sent.allSatisfy { $0.isFromCue && $0.target.ref == "s1" })
      #expect(sent.first?.content == "\(second.heading)\n照调研结论改 release.sh")
      #expect(try await store.card(second.id)?.piSessionID == nil)
      try await Server.run(library: sandbox.directory) { cue in
        let board = try await cue.call("task", ["action": "peek"])
        let peek = try await cue.call("task", ["action": "peek", "task": task.id.uuidString])
        let start = try await cue.refused("task", ["action": "start", "task": second.id.uuidString])
        let say = try await cue.refused("task", ["action": "say", "task": second.id.uuidString, "text": "还有"])
        #expect(board.contains("改脚本 › 发送中"), "\(board)")
        // 上一句可能已经执行：开工、说话都拒绝，免得同一句说两遍
        #expect(peek.contains("尚未确认") && start.contains("尚未确认") && say.contains("尚未确认"), "\(peek)\n\(start)\n\(say)")
      }

      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { [store] request, _ in
        _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID)
        return .succeeded
      }
      try await executor.start()
      let said = try await started
      #expect(said.contains("已送达"), "\(said)")
      _ = try await eventually(store, { try $0.card(second.id)?.piSessionID }) { $0 == "s1" }
      await executor.stop()

      let ends = { try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref) }
      _ = try await server.call("task", ["action": "done", "task": second.id.uuidString, "evidence": ["改好了"]])
      #expect(try await ends() == ["s1"])
      _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": ["两步都做完了"]])
      #expect(try await store.card(task.id)?.status == .done)
      #expect(try await ends() == ["s1"])
    }
  }

  @Test func aLeftBehindSessionEnds() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("通知改版", in: project.id)
    let sound = try await store.createTask("增加系统提示音和提示窗", under: task.id)
    let settings = try await store.createTask("设置里加开关", under: task.id)
    let docs = try await store.createTask("写说明", under: task.id)
    let opening = try await store.requestLaunch(LaunchRequest(project: project.id, prompt: sound.body, token: "first-step"), title: sound.heading, on: "mac-a", card: sound.id)
    let recorder = StateRecorder(store: store, hostID: "mac-a")
    try await recorder.update(sessionID: "s1", state: .settled, title: "s1", projectID: project.id, launchToken: opening.launch?.token, hosted: true)
    try await store.deleteDelivery(opening.id)
    try await recorder.update(sessionID: "s3", state: .settled, title: "s3", projectID: project.id, hosted: true)
    try await store.recordMacAgents(host: "mac-a", name: nil, [MacAgent(kind: .pi, model: nil, models: [])])
    try await Server.run(library: sandbox.directory) { server in
      let ends = { try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref).sorted() }

      _ = try await server.call("task", ["action": "done", "task": sound.id.uuidString, "evidence": ["提示音与提示窗都出来了"]])
      #expect(try await ends().isEmpty)  // 下一步还没开工，默认接着用它

      _ = try await server.call("task", ["action": "start", "task": settings.id.uuidString, "fresh": true])
      let launch = try #require(try await store.deliveryRequests().first { $0.mode == .known(.start) })
      #expect(try await ends() == ["s1"])
      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
      try await executor.start()
      _ = try await eventually(store, { try $0.deliveryRequest(launch.id)?.status }) { $0 == .known(.succeeded) }
      await executor.stop()
      _ = try await recorder.update(sessionID: "s1", state: .ended)  // 结束请求也执行了
      _ = try await recorder.update(sessionID: "s2", state: .settled, title: "设置里加开关", launchToken: launch.launch?.token, hosted: true)
      #expect(try await store.card(settings.id)?.piSessionID == "s2")

      _ = try await server.call("task", ["action": "done", "task": settings.id.uuidString, "evidence": ["开关能用"]])
      #expect(try await ends() == ["s1"])  // 写说明还没开工，默认接着用 s2
      try await store.bindSession("s3", to: docs.id)
      #expect(try await ends() == ["s1"])

      _ = try await server.call("task", ["action": "done", "task": docs.id.uuidString, "evidence": ["说明写好了"]])
      #expect(try await ends() == ["s1", "s2"])
    }
  }
}
#endif
