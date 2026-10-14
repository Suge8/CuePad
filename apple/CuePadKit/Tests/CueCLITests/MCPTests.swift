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

    // 没有草稿不开工（开新会话也一样，fresh 也一样）：先 edit 写草稿，什么请求都不写
    let blankID = try await server.call("task", ["action": "add", "title": "空着", "project": "演示"])["task"] as? String
    let blank = try #require(blankID.flatMap(UUID.init(uuidString:)))
    for arguments: [String: Any] in [["action": "start", "task": blank.uuidString], ["action": "start", "task": blank.uuidString, "fresh": true]] {
      let refused = try await server.request("tools/call", ["name": "task", "arguments": arguments])
      #expect(refused["isError"] as? Bool == true)
      #expect(((refused["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("edit") == true)
    }
    #expect(try await store.deliveryRequests().isEmpty)
    _ = try await store.trashCard(blank)

    _ = try await server.call("task", ["action": "start", "task": String(task.uuidString.prefix(6)), "model": "anthropic/claude-x", "effort": "high"])
    let launch = try #require(try await store.deliveryRequests().first)
    let step = try #require(try await store.children(of: task).first)
    #expect(launch.hostID == "mac-a" && launch.isFromCue && launch.target.name == "调研")
    #expect(launch.launch?.project == project.id && launch.launch?.prompt == "先读 release.sh")
    #expect(launch.launch?.model == PiModelKey(provider: "anthropic", id: "claude-x") && launch.launch?.thinking == .high)
    #expect(try await store.workingLeaf(of: task).id == step.id)
    let starting = try #require(try await server.call("task", ["action": "peek"])["tasks"] as? [[String: Any]])
    #expect((starting.first?["leaves"] as? [[String: Any]])?.first?["launching"] as? Bool == true)

    _ = try await server.call("tell", ["text": "调研结论要推送到 origin/main 吗？", "ask": "push", "task": task.uuidString])
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["调研结论要推送到 origin/main 吗？"])

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

  /// 会话交了结果、Cue 收尾（task done 带证据）：Cue 自己验收，顶层任务直接完成，不请用户收下；做完了的会话请它结束（算 Cue 发起），
  /// 给用户写一条结果（关联任务、正文带证据要点、不是"等你"）。再调一次只说已经完成，不重复写。整件事收尾要带证据。
  @Test(.timeLimit(.minutes(1))) func cueFinishesATopTaskAndReportsIt() async throws {
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

    let refused = try await server.request("tools/call", ["name": "task", "arguments": ["action": "done", "task": task.id.uuidString]])
    #expect(refused["isError"] as? Bool == true)
    #expect(try await store.card(task.id)?.status != .done)

    let evidence = "- 登录测试 12 个全过\n- 截图里错误提示对上了"
    for _ in 0..<2 { _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": evidence]) }
    #expect(try await store.card(task.id)?.status == .done)
    #expect(try await store.cueMessagesWaitingForYou().isEmpty)
    let reports = try await store.cueMessages().filter { $0.author == .known(.cue) }
    #expect(reports.count == 1)
    let report = try #require(reports.first)
    #expect(report.choices == nil && report.taskID == task.id)
    #expect(report.text.contains("修好登录页") && report.text.contains("登录测试 12 个全过") && report.text.contains("错误提示对上了"))
    let ends = try await store.deliveryRequests().filter { $0.mode == .known(.end) }
    #expect(ends.compactMap(\.target.ref) == ["s1"] && ends.allSatisfy { $0.isFromCue && $0.hostID == "mac-a" })
  }

  /// 带选项的"等你"只给收不回的那几类事（`CueAsk`），选项由 CuePad 给：Cue 自拟的确认（"照这个做吗"）发不出去。
  /// 用户选"以后推送都不用问"：记一条他的、一直记着的规矩（只管这个项目）；之后 Cue 再为这个项目问推送被拒，叫它直接做，
  /// 别的项目照问；他忘掉那条规矩又会问。
  @Test(.timeLimit(.minutes(1))) func onlyIrreversibleThingsAreAskedAndAlwaysAllowIsRemembered() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let demo = try await sandbox.project("演示"), other = try await sandbox.project("别的")
    let task = try await store.createTask("修好登录页", in: demo.id), elsewhere = try await store.createTask("改文案", in: other.id)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let confirm = try await server.request(
      "tools/call", ["name": "tell", "arguments": ["text": "调研方案好了，照这个做吗？", "ask": "confirm", "task": task.id.uuidString]])
    #expect(confirm["isError"] as? Bool == true)
    #expect(try await store.cueMessagesWaitingForYou().isEmpty)

    let reply = try await server.call("tell", ["text": "改好了，要推送到 origin/main 吗？", "ask": "push", "task": task.id.uuidString])
    let asked = try #require((reply["message"] as? String).flatMap(UUID.init(uuidString:)))
    let question = try #require(try await store.cueMessagesWaitingForYou().first)
    #expect(question.id == asked && question.choices == ["允许一次", "以后推送都不用问", "拒绝"])

    let rule = try #require(try await store.endCueQuestion(asked, .answered("以后推送都不用问")))
    #expect(rule.text == "以后推送都不用问（项目「演示」）" && rule.pinned && rule.source == .known(.you))
    let again = try await server.request(
      "tools/call", ["name": "tell", "arguments": ["text": "又改了一处，推送吗？", "ask": "push", "task": task.id.uuidString]])
    #expect(again["isError"] as? Bool == true)
    #expect(((again["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("直接做") == true)
    #expect(try await store.cueMessagesWaitingForYou().isEmpty)

    _ = try await server.call("tell", ["text": "文案要推送吗？", "ask": "push", "task": elsewhere.id.uuidString])
    try await store.forgetCueLine(rule.id)
    _ = try await server.call("tell", ["text": "又改了一处，推送吗？", "ask": "push", "task": task.id.uuidString])
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["文案要推送吗？", "又改了一处，推送吗？"])
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
    _ = try await store.createCard(body: "登录页白屏，查一下", under: task.id)
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    for bad in [["agent": "pi", "model": "gpt-5.1"], ["agent": "opencode", "model": "big-pickle"], ["agent": "cursor"]] {
      let refused = try await server.request("tools/call", ["name": "task", "arguments": ["action": "start", "task": task.id.uuidString].merging(bad) { $1 }])
      #expect(refused["isError"] as? Bool == true, "\(bad)")
    }
    #expect(try await store.deliveryRequests().isEmpty)

    let since = CueMarks(try await store.lastWrite())
    _ = try await server.call("task", ["action": "start", "task": task.id.uuidString, "agent": "codex", "model": "gpt-5.1", "effort": "high"])
    let launch = try #require(try await store.deliveryRequests().first)
    #expect(launch.isFromCue && launch.mode == .known(.start))
    #expect(launch.launch?.agent == .codex && launch.launch?.model == PiModelKey(provider: "codex", id: "gpt-5.1") && launch.launch?.thinking == .high)

    // 那台 Mac 上没有 Codex：执行器把失败写回
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _ in .failed("这台 Mac 上没有找到 Codex") }
    try await executor.start()
    defer { Task { await executor.stop() } }
    let changes = try await eventually(store, { try $0.cueChanges(after: since) }) { !$0.isEmpty }
    #expect(changes.map(\.kind) == [.failed] && changes.map(\.detail) == ["开工：这台 Mac 上没有找到 Codex"])
    #expect(changes.first?.taskID == task.id)
  }

  /// 分步做一件事、下一步接着用上一步的会话：上一步收尾前先开工下一步，草稿作为下一句发进那个会话，不开新会话；
  /// 话送到时这一步才绑上它（同界面、同开新会话"开成了才绑"），送到前看板与 peek 写"发送中"、不能再开工或说话，这时上一步收尾不结束会话。
  /// 下一步还没有草稿时开工报错，不先绑上。最后一步做完，会话结束（界面点圆圈同一条规则，见 App 的 `TaskFlowTests`）。
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
    let server = try Server(library: sandbox.directory)
    defer { server.close() }
    func refused(_ arguments: [String: Any]) async throws -> String? {
      let result = try await server.request("tools/call", ["name": "task", "arguments": arguments])
      guard result["isError"] as? Bool == true else { return nil }
      return (result["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    // 下一步还没有草稿：报错，什么都不写、不绑
    #expect(try await refused(["action": "start", "task": second.id.uuidString])?.contains("edit") == true)
    #expect(try await store.card(second.id)?.piSessionID == nil)
    #expect(try await store.deliveryRequests().isEmpty)

    _ = try await store.createCard(body: "照调研结论改 release.sh", under: second.id)
    _ = try await server.call("task", ["action": "start", "task": second.id.uuidString])
    let sent = try await store.deliveryRequests()
    #expect(sent.map(\.mode) == [.known(.send)] && sent.allSatisfy { $0.isFromCue && $0.target.ref == "s1" })
    #expect(sent.first?.content == "照调研结论改 release.sh")
    // 送到前：还没绑上，看板写发送中，不能再开工或说话
    #expect(try await store.card(second.id)?.piSessionID == nil)
    let board = try #require((try await server.call("task", ["action": "peek"])["tasks"] as? [[String: Any]])?.first)
    #expect((board["leaves"] as? [[String: Any]])?.first { $0["id"] as? String == second.id.uuidString.lowercased() }?["sending"] as? Bool == true)
    let peek = try await server.request("tools/call", ["name": "task", "arguments": ["action": "peek", "task": task.id.uuidString]])
    #expect(((peek["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("发送中") == true)
    #expect(try await refused(["action": "start", "task": second.id.uuidString])?.contains("送到") == true)
    #expect(try await refused(["action": "say", "task": second.id.uuidString, "text": "还有"])?.contains("送到") == true)
    // 上一步这时收尾：下一步的话正送进它的会话，会话留着
    _ = try await server.call("task", ["action": "done", "task": first.id.uuidString, "evidence": "- 看完了"])
    #expect(try await store.card(first.id)?.status == .done)
    #expect(try await store.deliveryRequests().allSatisfy { $0.mode != .known(.end) })

    // Mac 送到：记下这次发送，这一步绑上会话
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { [store] request in
      _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID)
      return .succeeded
    }
    try await executor.start()
    _ = try await eventually(store, { try $0.card(second.id)?.piSessionID }) { $0 == "s1" }
    await executor.stop()

    // 最后一步做完：没有叶子再用这个会话，结束；整件事收尾时不再请它结束第二次
    let ends = { try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref) }
    _ = try await server.call("task", ["action": "done", "task": second.id.uuidString, "evidence": "- 改好了"])
    #expect(try await ends() == ["s1"])
    _ = try await server.call("task", ["action": "done", "task": task.id.uuidString, "evidence": "- 两步都做完了"])
    #expect(try await store.card(task.id)?.status == .done)
    #expect(try await ends() == ["s1"])
  }

  /// 做完一步就收尾（"增加系统提示音和提示窗"做完了会话还挂着）：步骤完成时，它的会话不会被下一步接着用就结束——
  /// 下一步没开工，或下一步换了别的会话；之后再开工下一步不往那个正在结束的会话里发，开新会话。
  @Test(.timeLimit(.minutes(1))) func aFinishedStepEndsItsSessionUnlessTheNextStepUsesIt() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    let task = try await store.createTask("通知改版", in: project.id)
    try await store.setCueFollows(task.id, true)
    let sound = try await store.createTask("增加系统提示音和提示窗", under: task.id)
    let settings = try await store.createTask("设置里加开关", under: task.id)
    let docs = try await store.createTask("写说明", under: task.id)
    try await store.linkCard(sound.id, toSession: "s1")
    try await store.linkCard(settings.id, toSession: "s2")
    let recorder = PiStateRecorder(store: store, hostID: "mac-a")
    for session in ["s1", "s2"] { try await recorder.update(sessionID: session, state: .settled, title: session) }
    let server = try Server(library: sandbox.directory)
    defer { server.close() }
    let ends = { try await store.deliveryRequests().filter { $0.mode == .known(.end) }.compactMap(\.target.ref).sorted() }

    _ = try await server.call("task", ["action": "done", "task": sound.id.uuidString, "evidence": "- 提示音与提示窗都出来了"])
    #expect(try await ends() == ["s1"])
    _ = try await server.call("task", ["action": "done", "task": settings.id.uuidString, "evidence": "- 开关能用"])
    #expect(try await ends() == ["s1", "s2"])

    _ = try await store.createCard(body: "补一节通知设置的说明", under: docs.id)
    _ = try await server.call("task", ["action": "start", "task": docs.id.uuidString])
    #expect(try await store.deliveryRequests().filter { $0.mode != .known(.end) }.map(\.mode) == [.known(.start)])
  }

  /// Cue 撤回自己问过、他还没答的一条：从"等你"里消失，不交回给 Cue；同一次可以换个问法再问。他再点那条，报已经结束；撤回过的不能再撤。
  @Test(.timeLimit(.minutes(1))) func cueWithdrawsItsQuestion() async throws {
    try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "先构建 cuepad 产物：\(Self.binary.path)")
    let sandbox = try Sandbox()
    let store = sandbox.store
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let asked = try #require(try await server.call("tell", ["text": "要删掉旧的 release 分支吗？", "ask": "delete"])["message"] as? String)
    _ = try await server.call("tell", ["withdraw": String(asked.prefix(8)), "text": "旧分支先留着。要删掉 build 目录吗？", "ask": "delete"])
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["旧分支先留着。要删掉 build 目录吗？"])
    #expect(try await store.cueMessagesToDeliver().isEmpty)
    let id = try #require(UUID(uuidString: asked))
    await #expect(throws: CueStoreError.questionEnded) { try await store.endCueQuestion(id, .answered(CueAsk.once)) }
    let again = try await server.request("tools/call", ["name": "tell", "arguments": ["withdraw": asked]])
    #expect(again["isError"] as? Bool == true)
  }

  /// 看板上一件事的近况取在做的那一步；步骤都做完、整件事还没收尾时取最后做完的那一步（它的会话是最新的进展），不落回第一步。
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
      let leaf = try #require((item["leaves"] as? [[String: Any]])?.first)
      return (leaf["id"] as? String, leaf["session"] as? String)
    }

    _ = try await store.toggleDone(first.id)
    #expect(try await shown().session == "s2")  // 在做第二步
    _ = try await store.toggleDone(second.id)
    // 完成时刻直接给定先后（毫秒）：取的是最后做完的那一步，不是排在最后的那一步
    func finish(_ step: Card, atMinute minute: Int) throws {
      try RawDB(sandbox.directory.appending(path: "cuepad.db"))
        .exec("UPDATE cards SET completedAt = \(1_800_000_000_000 + minute * 60_000) WHERE id = '\(step.id.uuidString.lowercased())'")
    }
    try finish(first, atMinute: 0)
    try finish(second, atMinute: 1)
    let done = try await shown()
    #expect(done.session == "s2" && done.leaf == second.id.uuidString.lowercased())
    try finish(first, atMinute: 2)
    #expect(try await shown().session == "s1")
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

    // 照提示 fresh 开新会话：绑着会话的叶子也开新的（同样要先写草稿）
    _ = try await store.createCard(body: "换 opus 接着改", under: claude.id)
    _ = try await server.call("task", ["action": "start", "task": claude.id.uuidString, "agent": "claude", "model": "opus", "fresh": true])
    let launch = try #require(try await store.deliveryRequests().first)
    #expect(launch.mode == .known(.start) && launch.launch?.agent == .claudeCode && launch.launch?.model == PiModelKey(provider: "claude", id: "opus"))
  }
}
#endif
