#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing

extension MCPTests {
  /// 带选项的"等你"只给收不回的那几类事（`CueAsk`），选项由 CuePad 给：Cue 自拟的确认（"照这个做吗"）发不出去。
  /// 第二项照实际范围写：任务在项目里是"以后「项目」里推送不用问"，不关联任务时是"以后推送代码都不用问"；
  /// 选了第二项就把这句原话记成一条他说的、一直记着的记忆（不用先问的例外只在记忆里，问完任务挪了项目也照字面那句）。
  @Test(.timeLimit(.minutes(1))) func onlyIrreversibleThingsAreAskedAndAlwaysAllowIsRemembered() async throws {
    let sandbox = try Sandbox()
    let store = sandbox.store
    let demo = try await sandbox.project("演示"), other = try await sandbox.project("别的")
    let task = try await store.createTask("修好登录页", in: demo.id)
    try await Server.run(library: sandbox.directory) { server in
      try await server.refused("tell", ["text": "调研方案好了，照这个做吗？", "ask": "confirm", "task": task.id.uuidString])
      #expect(try await store.cueMessagesWaitingForYou().isEmpty)

      let reply = try await server.call("tell", ["text": "改好了，要推送到 origin/main 吗？", "ask": "push", "doing": "推送登录页的修复", "task": task.id.uuidString])
      let question = try #require(try await store.cueMessagesWaitingForYou().first)
      let asked = question.id
      #expect(reply.contains(asked.shortID) && question.choices == ["可以", "以后「演示」里推送代码不用问"])

      _ = try await store.moveCard(task.id, to: .top(project: other.id), after: nil)
      let noted = try #require(try await store.endCueQuestion(asked, .answered("以后「演示」里推送代码不用问")))
      let line = try #require(try await store.cueLine(noted))
      #expect(line.text == "以后「演示」里推送代码不用问" && line.pinned && line.source == .known(.you))

      _ = try await server.call("tell", ["text": "要推送吗？", "ask": "push", "doing": "推送分支清理"])
      let global = try #require(try await store.cueMessagesWaitingForYou().last)
      #expect(global.choices == ["可以", "以后推送代码都不用问"])
      #expect(try await store.endCueQuestion(global.id, .answered(CueAsk.once)) == nil)
      #expect(try await store.cueMemory().lines.map(\.text) == ["以后「演示」里推送代码不用问"])

      // 提问写出要做的动作，规矩那一类还要写出是哪条规矩；卡片与通知只露这两样
      #expect(try await server.refused("tell", ["text": "要推送吗？", "ask": "merge", "task": task.id.uuidString]).contains("doing"))
      let long = String(repeating: "长", count: CueAsking.phraseLimit + 1)
      #expect(try await server.refused("tell", ["text": "合并吗？", "ask": "merge", "doing": long, "task": task.id.uuidString]).contains("doing"))
      #expect(try await server.refused("tell", ["text": "改表吗？", "ask": "rule", "doing": "新建 password_resets 表"]).contains("rule"))
      _ = try await server.call(
        "tell", ["text": "要新建 password_resets 表。按你的规矩改库结构前先问；不建表后端做不下去。", "ask": "rule", "doing": "新建 password_resets 表",
                 "rule": "改数据库结构前先问我", "task": task.id.uuidString])
      let rule = try #require(try await store.cueMessagesWaitingForYou().last?.asking)
      #expect(rule.question == "可以新建 password_resets 表吗？" && rule.why == "你说过「改数据库结构前先问我」。")
      #expect(try await store.cueMessagesWaitingForYou().last?.choices == [CueAsk.once])
    }
  }

  /// Cue 撤回自己问过、他还没答的一条：从"等你"里消失，不交回给 Cue；同一次可以换个问法再问。他再点那条，报已经结束；撤回过的不能再撤。
  @Test(.timeLimit(.minutes(1))) func cueWithdrawsItsQuestion() async throws {
    let sandbox = try Sandbox()
    let store = sandbox.store
    try await Server.run(library: sandbox.directory) { server in
      try await server.call("tell", ["text": "要删掉旧的 release 分支吗？", "ask": "delete", "doing": "删掉旧的 release 分支"])
      let asked = try #require(try await store.cueMessagesWaitingForYou().first).id.uuidString.lowercased()
      _ = try await server.call("tell", ["withdraw": String(asked.prefix(8)), "text": "旧分支先留着。要删掉 build 目录吗？", "ask": "delete", "doing": "删掉 build 目录"])
      #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["旧分支先留着。要删掉 build 目录吗？"])
      #expect(try await store.cueMessagesToDeliver().isEmpty)
      let id = try #require(UUID(uuidString: asked))
      await #expect(throws: CueStoreError.questionEnded) { try await store.endCueQuestion(id, .answered(CueAsk.once)) }
      try await server.refused("tell", ["withdraw": asked])
    }
  }
}
#endif
