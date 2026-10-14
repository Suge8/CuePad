#if os(macOS)
import CueStore
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
}
#endif
