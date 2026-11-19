#if os(macOS)
import CueStore
import Foundation
import Synchronization
import Testing

@testable import CueCLI

@Suite struct PreviewCommandTests {
  private func page(_ sb: Fixture, _ name: String = "demo.html", _ text: String = "<h1>登录页</h1>") throws -> String {
    let url = sb.directory.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url.path
  }

  @Test func showStoresTheFilesTogetherForTheSessionFromTheEnvironmentAndReportsEach() async throws {
    let sb = try Fixture()
    // .ts 是 TypeScript（系统认作视频流）：按文本发
    let files = [try page(sb, "demo.html", "<link rel=\"stylesheet\" href=\"a.css\">"), try page(sb, "beep.m4a", "m4a"), try page(sb, "notes.docx", "docx"), try page(sb, "app.ts", "let a = 1")]
    let titles = ["登录页：首屏", "提示音", "需求文稿", "入口"]
    let reply = try array(try await sb.jsonValue(["show"] + files + titles.flatMap { ["--title", $0] }, environment: ["PI_SESSION_ID": "s1"]))

    let stored = try await sb.store.previews(of: "s1")
    #expect(stored.map(\.name) == ["demo.html", "beep.m4a", "notes.docx", "app.ts"] && Set(stored.map(\.createdAt)).count == 1)
    #expect(reply.map { $0.string("id") } == stored.map { $0.id.uuidString.lowercased() })
    #expect(reply.map { $0.string("kind") } == ["web", "audio", "document", "text"] && reply.allSatisfy { $0.string("session") == "s1" })
    #expect(reply.map { $0.string("title") } == titles && stored.map(\.title) == titles)
    #expect(reply[0]["bytes"] as? Int == "<link rel=\"stylesheet\" href=\"a.css\">".utf8.count && reply[0]["outsideReferences"] as? [String] == ["a.css"])
  }

  @Test func withoutASessionInTheEnvironmentItRefusesAndSaysWhy() async throws {
    let sb = try Fixture()
    let result = await sb.run("show", try page(sb))
    #expect(result.code != 0 && result.err.contains("PI_SESSION_ID"))
    let blank = await sb.run("show", try page(sb), environment: ["PI_SESSION_ID": ""])
    #expect(blank.code != 0 && blank.err.contains("PI_SESSION_ID"))
    #expect(try await sb.store.previews(of: "").isEmpty)
  }

  @Test func showRefusesWhatCannotBePreviewedWithAReasonAndExitCode() async throws {
    let sb = try Fixture()
    let env = ["PI_SESSION_ID": "s1"]
    let untitled = await sb.run("show", try page(sb), try page(sb, "b.html"), "--title", "登录页", environment: env)
    #expect(untitled.code != 0 && untitled.err.contains("--title"))
    let repeated = await sb.run("show", try page(sb), try page(sb, "b.html"), "--title", "登录页", "--title", "登录页", environment: env)
    #expect(repeated.code != 0 && repeated.err.contains("各不相同"))
    let missing = await sb.run("show", sb.directory.appending(path: "nope.html").path, "--title", "x", environment: env)
    #expect(missing.code != 0 && missing.err.contains("nope.html"))
    let archive = await sb.run("show", try page(sb, "a.zip", "zip"), "--title", "x", environment: env)
    #expect(archive.code != 0 && archive.err.contains("zip"))
    let compressed = await sb.run("show", try page(sb, "a.svgz", "svgz"), "--title", "x", environment: env)
    #expect(compressed.code != 0 && compressed.err.contains(".svgz") && !compressed.err.contains("、svgz"))
    #expect(try await sb.store.previews(of: "s1").isEmpty)
  }

  @Test func liveWithoutCuePadOpenOnThisLibraryFailsAndHandsNothingOver() async throws {
    let sb = try Fixture()
    let result = await sb.run("live", "5173", environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 1 && result.err.contains("CuePad 没开") && result.out.isEmpty)
    #expect(try await sb.store.liveAddresses().isEmpty)
  }

  @Test(arguments: ["https://example.com", "http://8.8.8.8:3000", "github.com/login"])
  func liveRefusesAnAddressOffThisMac(address: String) async throws {
    let sb = try Fixture()
    let result = await sb.run("live", address, environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 2 && result.err.contains("不是本机地址"))
    #expect(try await sb.store.liveAddresses().isEmpty)
  }

  /// 本机的几种写法过了地址这一关，停在下一关（CuePad 没开）。
  @Test(arguments: ["localhost:3000", "192.168.1.20:5173", "myapp.local:8080", "http://[::1]:3000", "devbox:8000"])
  func liveTakesTheLocalAddressesOfThisMac(address: String) async throws {
    let sb = try Fixture()
    let result = await sb.run("live", address, environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 1 && result.err.contains("CuePad 没开"))
  }

  @Test func liveActionsWithoutCuePadOpenFailAndAskForIt() async throws {
    let sb = try Fixture()
    let result = await sb.run("live", "snapshot", environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 1 && result.err.contains("CuePad 没开") && result.out.isEmpty)
  }

  private final class Received: Sendable {
    private let box = Mutex<[LiveChannel.Request]>([])
    func add(_ request: LiveChannel.Request) { box.withLock { $0.append(request) } }
    var all: [LiveChannel.Request] { box.withLock { $0 } }
  }

  /// 替 App 听这份库：App 用的同一个服务端（会话核对在它里面），交到手上的请求记下来、答一句。
  private func listen(_ sb: Fixture) throws -> (server: LiveChannel.Server, received: Received) {
    let received = Received()
    let server = try LiveChannel.Server(path: LiveChannel.socketPath(databasePath: sb.store.databasePath), store: sb.store) { request in
      received.add(request)
      return .done("点了 button \"登录\"")
    }
    return (server, received)
  }

  @Test func liveActionGoesToTheAppAsTheSessionInTheEnvironment() async throws {
    let sb = try Fixture()
    let (server, received) = try listen(sb)
    defer { withExtendedLifetime(server) {} }

    let result = await sb.run("live", "click", "a5", environment: ["CUEPAD_SESSION_ID": "s1"])
    #expect(result.code == 0 && result.out == "点了 button \"登录\"\n")
    #expect(received.all == [LiveChannel.Request(session: "s1", op: "click", args: .init(ref: "a5"))])

    let nobody = await sb.run("live", "click", "a5")
    #expect(nobody.code != 0 && nobody.err.contains("CUEPAD_SESSION_ID"))
    #expect(received.all.count == 1)
  }

  /// 会话记着在跑的 Agent 进程时，只有它的后代能以这个会话操作预览。这里发命令的是测试进程：它是自己父进程的后代，不是一个旁的 sleep 的后代。
  @Test func liveActionFromOutsideTheSessionsAgentIsRefused() async throws {
    let sb = try Fixture()
    let (server, received) = try listen(sb)
    defer { withExtendedLifetime(server) {} }
    let stranger = Process()
    stranger.executableURL = URL(filePath: "/bin/sleep")
    stranger.arguments = ["60"]
    try stranger.run()
    defer { stranger.terminate() }
    let other = try #require(SessionProcess.running(pid: stranger.processIdentifier))
    let parent = try #require(SessionProcess.running(pid: getppid()))
    for (session, process) in [("theirs", other), ("mine", parent)] {
      try RawDB(sb.url).exec("INSERT INTO piProcesses (sessionID, pid, startedAt) VALUES ('\(session)', \(process.pid), \(process.startedAt))")
    }

    let refused = await sb.run("live", "snapshot", environment: ["CUEPAD_SESSION_ID": "theirs"])
    #expect(refused.code == 1 && refused.err.contains("只能操作自己会话的活预览"))
    #expect(received.all.isEmpty)

    let allowed = await sb.run("live", "snapshot", environment: ["CUEPAD_SESSION_ID": "mine"])
    #expect(allowed.code == 0)
    #expect(received.all.map(\.session) == ["mine"])
  }

  @Test(arguments: ["ftp://localhost:5173", "localhost:99999", "0"])
  func liveRefusesAnAddressThePreviewCannotOpen(address: String) async throws {
    let sb = try Fixture()
    let result = await sb.run("live", address, environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 2 && result.err.contains("不是能打开的网页地址"))
    #expect(try await sb.store.liveAddresses().isEmpty)
  }
}
#endif
