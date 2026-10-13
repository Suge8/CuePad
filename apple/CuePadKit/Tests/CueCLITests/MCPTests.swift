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
    try await store.updateCueProfile { $0.hostID = "mac-a" }
    let server = try Server(library: sandbox.directory)
    defer { server.close() }

    let hello = try await server.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "pi", "version": "1"]])
    #expect(hello["protocolVersion"] as? String == "2025-11-25")
    let tools = try #require(try await server.request("tools/list", [:])["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["task", "tell", "memory"])
    #expect(tools.compactMap { ($0["description"] as? String)?.count }.reduce(0, +) <= 2000)

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

    _ = try await server.call("tell", ["text": "要不要顺便升级 Node？", "choices": ["要", "不要"], "task": task.uuidString])
    #expect(try await store.cueMessagesWaitingForYou().map(\.text) == ["要不要顺便升级 Node？"])

    let noted = try await server.call("memory", ["action": "note", "text": "发布前先跑检查", "pin": true])
    #expect(noted["line"] as? Int == 0)
    #expect(try await store.recallCue("发布前").lines.map(\.line.pinned) == [true])
    _ = try await server.call("memory", ["action": "forget", "line": "#0"])
    #expect(try await store.cueMemory().lines.map { $0.deletedAt != nil } == [true])
  }
}
#endif
