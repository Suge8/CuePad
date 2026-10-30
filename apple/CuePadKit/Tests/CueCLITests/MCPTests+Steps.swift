#if os(macOS)
import CueStore
import Foundation
import Testing

extension MCPTests {
  /// 分步做一件事（常规的"完成 → 开工下一步"）：上一步收尾时下一步还没开工，会话留着；下一步开工接着用它——草稿作为下一句发进去，不开新会话；
  /// 话送到时这一步才绑上那个会话（同界面、同开新会话"开成了才绑"），送到前看板与 peek 写"发送中"、不能再开工或说话；
  /// 最后一步做完，会话结束（界面点圆圈同一条规则，见 App 的 `TaskFlowTests`）。
  /// 开工的工具等送达结果时，另一个 `cuepad mcp`（Cue 的下一次调用）看到的是送到前的样子；Mac 送到后工具说已送达。
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
    try await store.linkCard(first.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, title: "调研")
    try await Server.run(library: sandbox.directory) { server in
      _ = try await server.call("task", ["action": "done", "task": first.id.uuidString, "evidence": ["看完了"]])
      #expect(try await store.card(first.id)?.status == .done)
      #expect(try await store.deliveryRequests().isEmpty)

      try await store.updateCard(second.id) { $0.body += "\n照调研结论改 release.sh" }
      async let started = server.call("task", ["action": "start", "task": second.id.uuidString])
      let sent = try await eventually(store, { try $0.deliveryRequests() }) { !$0.isEmpty }
      #expect(sent.map(\.mode) == [.known(.send)] && sent.allSatisfy { $0.isFromCue && $0.target.ref == "s1" })
      #expect(sent.first?.content == "\(second.heading)\n照调研结论改 release.sh")
      // 送到前：还没绑上，看板写发送中，不能再开工或说话
      #expect(try await store.card(second.id)?.piSessionID == nil)
      try await Server.run(library: sandbox.directory) { cue in
        let board = try await cue.call("task", ["action": "peek"])
        let peek = try await cue.call("task", ["action": "peek", "task": task.id.uuidString])
        let start = try await cue.refused("task", ["action": "start", "task": second.id.uuidString])
        let say = try await cue.refused("task", ["action": "say", "task": second.id.uuidString, "text": "还有"])
        #expect(board.contains("改脚本 › 发送中") && peek.contains("发送中") && start.contains("送到") && say.contains("送到"))
      }

      // Mac 送到：记下这次发送，这一步绑上会话
      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { [store] request, _ in
        _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID)
        return .succeeded
      }
      try await executor.start()
      let said = try await started
      #expect(said.contains("已送达"), "\(said)")
      _ = try await eventually(store, { try $0.card(second.id)?.piSessionID }) { $0 == "s1" }
      await executor.stop()

      // 最后一步做完：没有下一步了，会话结束；整件事收尾时不再请它结束第二次
      let ends = { try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref) }
      _ = try await server.call("task", ["action": "done", "task": second.id.uuidString, "evidence": ["改好了"]])
      #expect(try await ends() == ["s1"])
      _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": ["两步都做完了"]])
      #expect(try await store.card(task.id)?.status == .done)
      #expect(try await ends() == ["s1"])
    }
  }

  /// 换会话的那一刻与最后一步（"增加系统提示音和提示窗"做完了会话还挂着）：下一步开工用 fresh 开新会话时，上一步留着的会话结束；
  /// 下一步亲手绑到别的会话也一样；最后一步做完，它的会话结束。
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
    try await store.linkCard(sound.id, toSession: "s1")
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    for session in ["s1", "s3"] { try await recorder.update(sessionID: session, state: .settled, title: session) }
    try await store.recordMacAgents(host: "mac-a", name: nil, [MacAgent(kind: .pi, model: nil, models: [])])
    try await Server.run(library: sandbox.directory) { server in
      let ends = { try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref).sorted() }

      _ = try await server.call("task", ["action": "done", "task": sound.id.uuidString, "evidence": ["提示音与提示窗都出来了"]])
      #expect(try await ends().isEmpty)  // 下一步还没开工，默认接着用它

      _ = try await server.call("task", ["action": "start", "task": settings.id.uuidString, "fresh": true])
      let launch = try #require(try await store.deliveryRequests().first { $0.mode == .known(.start) })
      #expect(try await ends() == ["s1"])
      // Mac 开好新会话：会话记录带着请求里的 token 到了，这一步绑上它
      let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
      try await executor.start()
      _ = try await eventually(store, { try $0.deliveryRequest(launch.id)?.status }) { $0 == .known(.succeeded) }
      await executor.stop()
      _ = try await recorder.update(sessionID: "s1", state: .ended)  // 结束请求也执行了
      _ = try await recorder.update(sessionID: "s2", state: .settled, title: "设置里加开关", launchToken: launch.launch?.token)
      #expect(try await store.card(settings.id)?.piSessionID == "s2")

      _ = try await server.call("task", ["action": "done", "task": settings.id.uuidString, "evidence": ["开关能用"]])
      #expect(try await ends() == ["s1"])  // 写说明还没开工，默认接着用 s2
      try await store.bindSession("s3", to: docs.id)
      #expect(try await ends() == ["s1", "s2"])

      _ = try await server.call("task", ["action": "done", "task": docs.id.uuidString, "evidence": ["说明写好了"]])
      #expect(try await ends() == ["s1", "s2", "s3"])
    }
  }
}
#endif
