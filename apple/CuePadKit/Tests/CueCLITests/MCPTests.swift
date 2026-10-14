#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing

/// Cue 的大脑经 `cuepad mcp`（stdio，一行一个 JSON-RPC）派活、说话、记东西：真实子进程，结果落在库里。
@Suite struct MCPTests {
  private final class Anchor {}
  private static var binary: URL {
    Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "cuepad")
  }

  /// 一个 `cuepad mcp` 子进程：写一行请求，读一行回应。
  private final class Server: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe()
    var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    var next = 0

    init(library: URL) throws {
      process.executableURL = MCPTests.binary
      process.arguments = ["mcp"]
      process.environment = ["CUEPAD_LIBRARY_DIR": library.path]
      process.standardInput = input
      process.standardOutput = output
      lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
      try process.run()
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
      next += 1
      let message: [String: Any] = ["jsonrpc": "2.0", "id": next, "method": method, "params": params]
      input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
      let line = try #require(try await lines.next())
      let reply = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      #expect(reply["id"] as? Int == next)
      return try #require(reply["result"] as? [String: Any], "\(reply)")
    }

    /// 调一个工具，返回 structuredContent；期望不出错。
    func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
      let result = try await request("tools/call", ["name": tool, "arguments": arguments])
      #expect(result["isError"] as? Bool == false, "\(result)")
      return try #require(result["structuredContent"] as? [String: Any])
    }

    func close() {
      try? input.fileHandleForWriting.close()
      process.waitUntilExit()
    }
  }

  @Test(.timeLimit(.minutes(1))) func cueDispatchesATaskTellsAndRemembersThroughMCP() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let hello = try await server.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "pi", "version": "1"]])
    #expect(hello["protocolVersion"] as? String == "2025-11-25")
    let tools = try #require(try await server.request("tools/list", [:])["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["task", "tell", "memory"])

    let added = try await server.call(
      "task", ["action": "add", "title": "重写发布脚本", "project": "演示", "steps": ["调研", "改脚本"], "prompt": "先读 release.sh"])
    let taskID = try #require(added["task"] as? String)
    let task = try #require(UUID(uuidString: taskID))
    let board = try #require(try await server.call("task", ["action": "peek"])["tasks"] as? [[String: Any]])
    #expect(board.compactMap { $0["title"] as? String } == ["重写发布脚本"])

    _ = try await server.call("task", ["action": "start", "task": String(task.uuidString.prefix(6)), "model": "anthropic/claude-x", "effort": "high"])
    let launch = try #require(try await store.deliveryRequests().first)
    let step = try #require(try await store.children(of: task).first)
    #expect(launch.hostID == "mac-a" && launch.isFromCue && launch.target.name == "调研")
    #expect(launch.launch?.project == project.id && launch.launch?.prompt == "先读 release.sh")
    #expect(launch.launch?.model == PiModelKey(provider: "anthropic", id: "claude-x") && launch.launch?.thinking == .high)
    #expect(try await store.workingLeaf(of: task).id == step.id)
    let starting = try #require(try await server.call("task", ["action": "peek"])["tasks"] as? [[String: Any]])
    #expect(starting.first?["launching"] as? Bool == true)

    _ = try await server.call("tell", ["text": "要不要顺便升级 Node？", "choices": ["要", "不要"], "task": task.uuidString])
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["要不要顺便升级 Node？"])

    let noted = try await server.call("memory", ["action": "note", "text": "发布前先跑检查", "pin": true])
    #expect(noted["line"] as? Int == 0)
    #expect(try await store.recallCue("发布前").lines.map(\.line.pinned) == [true])
    _ = try await server.call("memory", ["action": "forget", "line": "#0"])
    #expect(try await store.cueMemory().lines.map { $0.deletedAt != nil } == [true])
  }

  /// 停用之后 Cue 的工具不能再派活（停用只清启用时刻，住在哪台 Mac 还留着）。
  @Test(.timeLimit(.minutes(1))) func aDisabledCueCannotDispatchWork() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = nil
    }
    let task = try await store.createTask("跑检查", in: project.id)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let result = try await server.request("tools/call", ["name": "task", "arguments": ["action": "start", "task": task.id.uuidString]])
    #expect(result["isError"] as? Bool == true)
    #expect(try await store.deliveryRequests().isEmpty)
  }

  /// 没给项目建的任务落在未分类：Cue 用 edit 的 project 把它连同步骤与草稿挪进项目，就能开工。
  @Test(.timeLimit(.minutes(1))) func cueMovesAnUnfiledTaskIntoAProject() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("greet")
    try await store.setDirectory("/tmp/greet", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let added = try await server.call("task", ["action": "add", "title": "加问候语", "steps": ["写文案"], "prompt": "先看现有问候"])
    let taskID = try #require(added["task"] as? String)
    let task = try #require(UUID(uuidString: taskID))
    let step = try #require(try await store.children(of: task).first)
    let draft = try #require(try await store.children(of: step.id).first)
    #expect(try await store.card(task)?.projectID == nil)

    _ = try await server.call("task", ["action": "edit", "task": taskID, "project": "greet"])
    for id in [task, step.id, draft.id] { #expect(try await store.card(id)?.projectID == project.id) }
    _ = try await server.call("task", ["action": "start", "task": taskID])
    #expect(try await store.deliveryRequests().first?.launch?.project == project.id)

    // 你亲手给步骤绑上会话：绑了会话的叶子不留草稿，Cue 再写草稿被拒（叫它用 say），什么都不留下
    try await store.bindSession("s9", to: step.id)
    let rejected = try await server.request("tools/call", ["name": "task", "arguments": ["action": "edit", "task": taskID, "prompt": "再看看"]])
    #expect(rejected["isError"] as? Bool == true)
    #expect(try await store.children(of: step.id).isEmpty)
  }

  /// peek 一件事：每个叶子最新的那条回答给全文（至多 4000 字，超了截尾并注明），更早的截短。
  @Test(.timeLimit(.minutes(1))) func peekGivesTheLatestReplyInFull() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let task = try await store.createTask("跑测试", in: nil)
    try await store.linkCard(task.id, toSession: "s1")
    let older = String(repeating: "旧", count: 500), output = "全部通过 " + String(repeating: "过", count: 4500) + "尾巴"
    try await store.writePiTranscript(PiTranscript(
      sessionID: "s1",
      messages: [
        PiChatMessage(sessionID: "s1", entryID: "1", seq: 1, role: .user, text: "跑一遍", at: .now),
        PiChatMessage(sessionID: "s1", entryID: "2", seq: 2, role: .pi, text: older, at: .now),
        PiChatMessage(sessionID: "s1", entryID: "3", seq: 3, role: .user, text: "贴输出", at: .now),
        PiChatMessage(sessionID: "s1", entryID: "4", seq: 4, role: .pi, text: output, at: .now),
      ],
      recap: PiRecap()))
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let result = try await server.request("tools/call", ["name": "task", "arguments": ["action": "peek", "task": task.id.uuidString]])
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    // 前 4000 字里的"过"（含开头"全部通过"的那个）都在：长串重复字符的子串查找不可靠，按个数比
    #expect(text.filter { $0 == "过" }.count == output.prefix(4000).filter { $0 == "过" }.count)
    #expect(!text.contains("尾巴") && text.contains("后面还有 \(output.count - 4000) 字"))
    #expect(!text.contains(older) && text.contains(String(older.prefix(200))))
  }

  /// 刚启用或巡视时 Cue 看用户手上所有没做完的事：谁在跟进都列，按项目分组、未分类在最后，做完的不列；太多时只列 60 行，说还有几件。
  @Test(.timeLimit(.minutes(1))) func cueSeesEveryOpenTaskGroupedByProject() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    let mine = try await store.createTask("用户自己的事", in: project.id)
    let followed = try await store.createTask("Cue 跟进的事", in: nil)
    try await store.setCueFollows(followed.id, true)
    let done = try await store.createTask("做完的事", in: project.id)
    try await store.setStatus(done.id, .done)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let all = try await server.request("tools/call", ["name": "task", "arguments": ["action": "peek", "all": true]])
    let text = try #require((all["content"] as? [[String: Any]])?.first?["text"] as? String)
    let tasks = try #require((all["structuredContent"] as? [String: Any])?["tasks"] as? [[String: Any]])
    #expect(tasks.compactMap { $0["id"] as? String } == [mine.id, followed.id].map { $0.uuidString.lowercased() })
    #expect(tasks.compactMap { $0["follows"] as? Bool } == [false, true])
    #expect(text.split(separator: "\n").filter { $0.hasSuffix("：") && !$0.hasPrefix("-") }.dropFirst().map(String.init) == ["演示：", "未分类："])

    for index in 0..<70 { _ = try await store.createTask("事 \(index)", in: nil) }
    let many = try await server.request("tools/call", ["name": "task", "arguments": ["action": "peek", "all": true]])
    let lines = try #require((many["content"] as? [[String: Any]])?.first?["text"] as? String).split(separator: "\n")
    #expect(lines.count == 60)
    let shown = lines.filter { $0.hasPrefix("- ") }.count
    #expect(lines.last.map(String.init) == "还有 \(72 - shown) 件")
  }

  /// 会话交了结果、Cue 收尾（task done 带证据）：顶层任务不直接完成，写一条"等你"请用户收下——选项是收下 / 再改改、关联任务、正文带证据要点；
  /// 再调一次不重复写。用户答"收下"就是收下：任务完成、做完了的会话请它结束（算用户发起），这条回答照常交给 Cue。
  /// 用户用话说了收下，Cue 带 accepted 直接完成。
  @Test(.timeLimit(.minutes(1))) func aTopTaskWaitsForTheUserToAcceptIt() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("修好登录页", in: project.id)
    try await store.setCueFollows(task.id, true)
    try await store.linkCard(task.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, title: "修好登录页")
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let evidence = "- 登录测试 12 个全过\n- 截图里错误提示对上了"
    for _ in 0..<2 { _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": evidence]) }
    let asked = try await store.cueMessagesWaitingForYou()
    #expect(asked.count == 1)
    let question = try #require(asked.first)
    #expect(question.author == .known(.cue) && question.choices == CueAcceptance.choices && question.taskID == task.id)
    #expect(question.text.contains("登录测试 12 个全过") && question.text.contains("错误提示对上了"))
    #expect(try await store.card(task.id)?.status != .done)
    #expect(try await store.deliveryRequests().isEmpty)

    try await store.answerCueMessage(question.id, answer: CueAcceptance.accept)
    #expect(try await store.card(task.id)?.status == .done)
    let ends = try await store.deliveryRequests().filter { $0.mode == .known(.end) }
    #expect(ends.compactMap(\.target.ref) == ["s1"] && ends.allSatisfy { !$0.isFromCue && $0.hostID == "mac-a" })
    #expect(try await store.cueMessagesToDeliver().map(\.id) == [question.id])

    let spoken = try await store.createTask("改文案", in: project.id)
    _ = try await server.call("task", ["action": "done", "task": spoken.id.uuidString, "evidence": "- 文案改好了", "accepted": true])
    #expect(try await store.card(spoken.id)?.status == .done)
    #expect(try await store.cueMessagesWaitingForYou().isEmpty)
  }

  /// Cue 派活时选哪家 Agent 开会话：请求带着这家与模型（写法同给大脑的清单：Claude Code、Codex 只写 id，提供方补成这家；
  /// Pi、OpenCode 要写 provider/id）。
  /// 那台 Mac 开不了这家时，失败是 Cue 跟进的事里的一条变化，写着"开工：原因"，Cue 下次醒来看得到。
  @Test(.timeLimit(.minutes(1))) func cueStartsASessionWithTheAgentItChose() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("修好登录页", in: project.id)
    try await store.setCueFollows(task.id, true)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    for bad in [["agent": "pi", "model": "gpt-5.1"], ["agent": "opencode", "model": "big-pickle"], ["agent": "cursor"]] {
      let refused = try await server.request("tools/call", ["name": "task", "arguments": ["action": "start", "task": task.id.uuidString].merging(bad) { $1 }])
      #expect(refused["isError"] as? Bool == true, "\(bad)")
    }
    #expect(try await store.deliveryRequests().isEmpty)

    let since = Date()
    _ = try await server.call("task", ["action": "start", "task": task.id.uuidString, "agent": "codex", "model": "gpt-5.1", "effort": "high"])
    let launch = try #require(try await store.deliveryRequests().first)
    #expect(launch.isFromCue && launch.mode == .known(.start))
    #expect(launch.launch?.agent == .codex && launch.launch?.model == PiModelKey(provider: "codex", id: "gpt-5.1") && launch.launch?.thinking == .high)

    // 那台 Mac 上没有 Codex：执行器把失败写回
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _ in .failed("这台 Mac 上没有找到 Codex") }
    try await executor.start()
    defer { Task { await executor.stop() } }
    let changes = try await eventually(store, { try $0.cueChanges(since: since) }) { !$0.isEmpty }
    #expect(changes.map(\.kind) == [.failed] && changes.map(\.detail) == ["开工：这台 Mac 上没有找到 Codex"])
    #expect(changes.first?.taskID == task.id)
  }

  /// 分步做一件事：上一步收尾不结束会话，下一步开工接着用它——绑上、草稿作为下一句发进去，不开新会话；
  /// 你收下整件事时，这个会话按做完了的规则结束。
  @Test(.timeLimit(.minutes(1))) func stepsOfATaskContinueInTheSameSession() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("重写发布脚本", in: project.id)
    try await store.setCueFollows(task.id, true)
    let first = try await store.createTask("调研", under: task.id), second = try await store.createTask("改脚本", under: task.id)
    try await store.linkCard(first.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, title: "调研")
    _ = try await store.createCard(body: "照调研结论改 release.sh", under: second.id)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    _ = try await server.call("task", ["action": "done", "task": first.id.uuidString, "evidence": "- 看完了"])
    #expect(try await store.card(first.id)?.status == .done)
    #expect(try await store.deliveryRequests().isEmpty)

    _ = try await server.call("task", ["action": "start", "task": second.id.uuidString])
    #expect(try await store.card(second.id)?.piSessionID == "s1")
    let sent = try await store.deliveryRequests()
    #expect(sent.map(\.mode) == [.known(.send)] && sent.allSatisfy { $0.isFromCue && $0.target.ref == "s1" })
    #expect(sent.first?.content == "照调研结论改 release.sh")

    _ = try await server.call("task", ["action": "done", "task": second.id.uuidString, "evidence": "- 改好了"])
    _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": "- 两步都做完了"])
    #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
    let asked = try #require(try await store.cueMessagesWaitingForYou().first)
    try await store.answerCueMessage(asked.id, answer: CueAcceptance.accept)
    #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref) == ["s1"])
  }

  /// 验收挂着时 Cue 又对这件事的会话说话（返工）：那条验收作废——去掉选项，留在对话里当一句话，不再算等你；
  /// 返工完再收尾写一条新的验收、带新证据。Cue 开工同样作废；Cue 别的提问不动，你自己对会话说话也不动。
  @Test(.timeLimit(.minutes(1))) func reworkWithdrawsThePendingAcceptance() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("加语言参数", in: nil)
    try await store.setCueFollows(task.id, true)
    try await store.linkCard(task.id, toSession: "s1")
    try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": "- 旧证据"])
    _ = try await server.call("tell", ["text": "README 要不要中文？", "choices": ["要", "不要"], "task": task.id.uuidString])
    let stale = try #require(try await store.cueMessagesWaitingForYou().first { $0.choices == CueAcceptance.choices })

    _ = try await server.call("task", ["action": "say", "task": task.id.uuidString, "text": "换模型再查一遍"])
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["README 要不要中文？"])
    let withdrawn = try #require(try await store.cueMessages().first { $0.id == stale.id })
    #expect(withdrawn.choices == nil && withdrawn.text.contains("旧证据"))

    _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": "- 新证据"])
    let fresh = try await store.cueMessagesWaitingForYou().filter { $0.choices == CueAcceptance.choices }
    #expect(fresh.count == 1 && fresh.first?.id != stale.id && fresh.first?.text.contains("新证据") == true)

    // Cue 带着新草稿开工：同样作废
    _ = try await store.createCard(body: "再跑一遍测试", under: task.id)
    _ = try await server.call("task", ["action": "start", "task": task.id.uuidString])
    #expect(try await store.cueMessagesWaitingForYou().filter { $0.choices == CueAcceptance.choices }.isEmpty)

    // 你自己经 CuePad 对会话说话：验收还挂着
    _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": "- 又跑了一遍"])
    let latest = try #require(try await store.cueMessagesWaitingForYou().first { $0.choices == CueAcceptance.choices })
    _ = try await store.requestDelivery("我先看看", to: SendTarget(kind: .piSession, name: "加语言参数", ref: "s1"), on: "mac-a")
    #expect(try await store.cueMessagesWaitingForYou().contains { $0.id == latest.id })
  }

  /// 看板上一件事的近况取在做的那一步；步骤都做完、等你收下时取最后做完的那一步（它的会话是最新的进展），不落回第一步。
  @Test(.timeLimit(.minutes(1))) func theBoardShowsTheStepLastWorkedOn() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let task = try await store.createTask("加语言参数", in: nil)
    try await store.setCueFollows(task.id, true)
    let first = try await store.createTask("加 --lang", under: task.id), second = try await store.createTask("写 README", under: task.id)
    try await store.linkCard(first.id, toSession: "s1")
    try await store.linkCard(second.id, toSession: "s2")
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    for session in ["s1", "s2"] { try await recorder.update(sessionID: session, state: .settled) }
    let server = try Server(library: sandbox.directory)
    defer { server.close() }
    func shown() async throws -> (leaf: String?, session: String?) {
      let item = try #require((try await server.call("task", ["action": "peek"])["tasks"] as? [[String: Any]])?.first)
      return (item["leaf"] as? String, item["session"] as? String)
    }

    _ = try await store.toggleDone(first.id)
    #expect(try await shown().session == "s2")  // 在做第二步
    try await Task.sleep(for: .milliseconds(5))  // 完成时刻分得出先后
    _ = try await store.toggleDone(second.id)
    let done = try await shown()
    #expect(done.session == "s2" && done.leaf == second.id.uuidString.lowercased())
  }

  /// 会话因为模型出错，你让换个模型：Cue 的 say 带 model、effort，先请会话换模型（与界面换模型同一种请求），再说这句；
  /// 换不了模型的会话（终端里的 Claude Code）直接报错，什么都不写，告诉 Cue 可以 fresh 开新会话。
  @Test(.timeLimit(.minutes(1))) func cueSwitchesTheSessionModelBeforeSpeaking() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    let pi = try await store.createTask("修好登录页", in: nil), claude = try await store.createTask("改文案", in: project.id)
    try await store.linkCard(pi.id, toSession: "s1")
    try await store.linkCard(claude.id, toSession: "c1")
    try await recorder.update(sessionID: "s1", state: .error, title: "修好登录页")
    try await recorder.update(sessionID: "c1", state: .error, title: "改文案", agent: .claudeCode)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    _ = try await server.call(
      "task", ["action": "say", "task": pi.id.uuidString, "text": "用 luna 重试", "model": "openai/gpt-6-luna", "effort": "high"])
    let requests = try await store.deliveryRequests(toSession: "s1")  // 执行器按这个先后执行
    #expect(requests.map(\.mode) == [.known(.config), .known(.send)] && requests.allSatisfy(\.isFromCue))
    #expect(requests.first?.config == PiConfig(model: PiModelKey(provider: "openai", id: "gpt-6-luna"), thinking: .high))
    #expect(requests.last?.content == "用 luna 重试")

    let refused = try await server.request(
      "tools/call", ["name": "task", "arguments": ["action": "say", "task": claude.id.uuidString, "text": "换个模型", "model": "opus"]])
    #expect(refused["isError"] as? Bool == true)
    let reason = try #require((refused["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(reason.contains("换不了模型") && reason.contains("fresh"))
    #expect(try await store.deliveryRequests().count == 2)

    // 作答同样先换模型再答；答案无效时什么都不写，换不了模型的会话报错
    let question = PiQuestion(promptID: "p", kind: .confirm, text: "继续？")
    try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
    try await recorder.update(sessionID: "c1", state: .waitingForUser, question: question, agent: .claudeCode)
    let answer = ["action": "say", "task": pi.id.uuidString, "when": "answer", "model": "openai/gpt-6-sol", "effort": "low"]
    let invalid = try await server.request("tools/call", ["name": "task", "arguments": answer.merging(["value": "也许"]) { $1 }])
    #expect(invalid["isError"] as? Bool == true)
    #expect(try await store.deliveryRequests().count == 2)
    let claudeAnswer = try await server.request(
      "tools/call", ["name": "task", "arguments": ["action": "say", "task": claude.id.uuidString, "when": "answer", "value": "yes", "model": "opus"]])
    #expect(((claudeAnswer["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("换不了模型") == true)
    #expect(try await store.deliveryRequests().count == 2)
    _ = try await server.call("task", answer.merging(["value": "yes"]) { $1 })
    let answered = try await store.deliveryRequests(toSession: "s1").suffix(2)
    #expect(answered.map(\.mode) == [.known(.config), .known(.answer)] && answered.allSatisfy(\.isFromCue))
    #expect(answered.first?.config == PiConfig(model: PiModelKey(provider: "openai", id: "gpt-6-sol"), thinking: .low))

    // 照提示 fresh 开新会话：绑着会话的叶子也开新的
    _ = try await server.call("task", ["action": "start", "task": claude.id.uuidString, "agent": "claude", "model": "opus", "fresh": true])
    let launch = try #require(try await store.deliveryRequests().first)
    #expect(launch.mode == .known(.start) && launch.launch?.agent == .claudeCode && launch.launch?.model == PiModelKey(provider: "claude", id: "opus"))
  }
}
#endif
