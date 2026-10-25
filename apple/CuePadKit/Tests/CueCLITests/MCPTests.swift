#if os(macOS)
import CueStore
import Foundation
import Testing

/// Cue 的大脑经 `cuepad mcp`（stdio，一行一个 JSON-RPC）派活、说话、记东西：真实子进程，结果落在库里。
@Suite struct MCPTests {
  /// 一个 `cuepad mcp` 子进程：写一行请求，读一行回应。回应由它自己的线程读：两个子进程同时有调用在等（一个工具在等送达结果时
  /// 另一个照常回应）也互不挡着，`FileHandle.bytes` 的读取会把它们排成一队。
  final class Server: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe()
    var lines: AsyncStream<String>.Iterator
    var next = 0
    private let exit: ProcessExit

    private init(library: URL) throws {
      process.executableURL = try cuepadBinary()
      process.arguments = ["mcp"]
      process.environment = ["CUEPAD_LIBRARY_DIR": library.path]
      process.standardInput = input
      process.standardOutput = output
      let (replies, reply) = AsyncStream<String>.makeStream()
      lines = replies.makeAsyncIterator()
      let reader = output.fileHandleForReading
      Thread.detachNewThread {
        var buffer = Data()
        while case let chunk = reader.availableData, !chunk.isEmpty {
          buffer.append(chunk)
          while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            reply.yield(String(decoding: buffer[..<end], as: UTF8.self))
            buffer.removeSubrange(...end)
          }
        }
        reply.finish()
      }
      exit = try ProcessExit(launching: process)
    }

    /// 起一个 `cuepad mcp` 交给 `body`；之后（失败也一样）关它的输入、等它退出。
    static func run(library: URL, _ body: (Server) async throws -> Void) async throws {
      let server = try Server(library: library)
      let outcome: Result<Void, any Error>
      do { outcome = .success(try await body(server)) } catch { outcome = .failure(error) }
      try? server.input.fileHandleForWriting.close()
      _ = await server.exit.value  // 关了输入就该自己退出；不退出由测试时限报
      try outcome.get()
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
      next += 1
      let message: [String: Any] = ["jsonrpc": "2.0", "id": next, "method": method, "params": params]
      input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
      let line = try #require(await lines.next())
      let reply = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      #expect(reply["id"] as? Int == next)
      return try #require(reply["result"] as? [String: Any], "\(reply)")
    }

    /// 调一个工具，返回正文；期望不出错。
    @discardableResult
    func call(_ tool: String, _ arguments: [String: Any]) async throws -> String { try await tools(tool, arguments, isError: false) }

    /// 调一个工具，期望被退回（`isError`），返回给 Cue 的理由。
    @discardableResult
    func refused(_ tool: String, _ arguments: [String: Any]) async throws -> String { try await tools(tool, arguments, isError: true) }

    private func tools(_ tool: String, _ arguments: [String: Any], isError: Bool) async throws -> String {
      let result = try await request("tools/call", ["name": tool, "arguments": arguments])
      #expect(result["isError"] as? Bool == isError, "\(tool) \(arguments) → \(result)")
      return try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    }
  }

  @Test func cueDispatchesATaskTellsAndRemembersThroughMCP() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = .now
    }
    try await store.recordMacAgents(host: "mac-a", name: nil, [MacAgent(kind: .pi, model: nil, models: [])])
    try await Server.run(library: sandbox.directory) { server in
      let hello = try await server.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "pi", "version": "1"]])
      #expect(hello["protocolVersion"] as? String == "2025-11-25")
      let tools = try #require(try await server.request("tools/list", [:])["tools"] as? [[String: Any]])
      #expect(tools.compactMap { $0["name"] as? String } == ["task", "tell", "memory"])

      try await server.call("task", ["action": "add", "title": "重写发布脚本", "project": "演示", "steps": ["调研", "改脚本"]])
      let task = try #require(try await store.tasks(.todo).flatMap(\.tasks).first { $0.heading == "重写发布脚本" }).id
      let research = try #require(try await store.children(of: task).first)
      _ = try await server.call("task", ["action": "edit", "task": research.id.uuidString, "body": "先读 release.sh"])
      #expect(try await server.call("task", ["action": "peek"]).contains("重写发布脚本（\(task.shortID)）"))
      // 名字宽过上限（汉字算 2）：整件退回，告诉 Cue 怎么改，什么都不写
      for long: [String: Any] in [["title": "让 Agent 编译测试排队、模拟器复用、测试快速失败"], ["title": "发布", "steps": ["调研", "把发布脚本改成按渠道分别打包上传"]]] {
        #expect(try await server.refused("task", ["action": "add"].merging(long) { $1 }).contains("上限 24"))
      }
      #expect(try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).filter { $0.parentID == nil }.count == 1)

      _ = try await server.call("task", ["action": "start", "task": String(task.uuidString.prefix(6)), "model": "anthropic/claude-x", "effort": "high"])
      let launch = try #require(try await store.deliveryRequests().first)
      let step = try #require(try await store.children(of: task).first)
      #expect(launch.hostID == "mac-a" && launch.isFromCue && launch.target.name == "调研")
      #expect(launch.launch?.project == project.id && launch.launch?.prompt == "重写发布脚本\n\n调研\n先读 release.sh")  // 开新会话：顶层任务作背景在前
      #expect(launch.launch?.model == PiModelKey(provider: "anthropic", id: "claude-x") && launch.launch?.thinking == .high)
      #expect(try await store.workingLeaf(of: task).id == step.id)
      #expect(try await server.call("task", ["action": "peek"]).contains("调研 › 正在开会话"))

      _ = try await server.call("tell", ["text": "调研结论要推送到 origin/main 吗？", "ask": "push", "doing": "推送登录页的修复", "task": task.uuidString])
      #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["调研结论要推送到 origin/main 吗？"])

      #expect(try await server.call("memory", ["action": "note", "text": "发布前先跑检查", "pin": true]).contains("#0"))
      #expect(try await store.recallCue("发布前").lines.map(\.line.pinned) == [true])
      _ = try await server.call("memory", ["action": "forget", "line": "#0"])
      #expect(try await store.cueMemory().lines.map { $0.deletedAt != nil } == [true])
    }
  }

  /// 停用之后 Cue 的工具不能再派活（停用只清启用时刻，运行在哪台 Mac 还留着）。
  @Test func aDisabledCueCannotDispatchWork() async throws {
    let sandbox = try Fixture()
    let store = sandbox.store
    let project = try await sandbox.project("演示")
    try await store.setDirectory("/tmp/demo", for: project.id)
    try await store.updateCueProfile {
      $0.hostID = "mac-a"
      $0.enabledAt = nil
    }
    let task = try await store.createTask("跑检查", in: project.id)
    try await Server.run(library: sandbox.directory) { server in
      try await server.refused("task", ["action": "start", "task": task.id.uuidString])
      #expect(try await store.deliveryRequests().isEmpty)
    }
  }
}
#endif
