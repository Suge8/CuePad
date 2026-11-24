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
  }

  @Test(arguments: ["https://example.com", "http://8.8.8.8:3000", "github.com/login"])
  func liveRefusesAnAddressOffThisMac(address: String) async throws {
    let sb = try Fixture()
    let (server, received) = try listen(sb)
    defer { withExtendedLifetime(server) {} }
    let result = await sb.run("live", address, environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 2 && result.err.contains("不是本机地址"))
    #expect(received.all.isEmpty)
  }

  @Test(arguments: ["localhost:3000", "192.168.1.20:5173", "myapp.local:8080", "http://[::1]:3000", "devbox:8000"])
  func liveTakesTheLocalAddressesOfThisMac(address: String) async throws {
    let sb = try Fixture()
    let url = try #require(LiveAddress.url(from: address))
    let (server, received) = try listen(sb, answer: .done("预览滑开了。", .init(url: url.absoluteString)))
    defer { withExtendedLifetime(server) {} }
    let result = await sb.run("live", address, environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 0 && result.out.hasPrefix("预览滑开了。"), "\(result.err)")
    #expect(received.all == [LiveChannel.Request(session: "s1", op: .open(url))])
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

  private func listen(_ sb: Fixture, answer: LiveChannel.Reply = .done("点了 button \"登录\"")) throws -> (server: LiveChannel.Server, received: Received) {
    let received = Received()
    let server = try LiveChannel.Server(path: LiveChannel.socketPath(databasePath: sb.store.databasePath), store: sb.store) { request in
      received.add(request)
      return answer
    }
    return (server, received)
  }

  @Test func liveActionGoesToTheAppAsTheSessionInTheEnvironment() async throws {
    let sb = try Fixture()
    let (server, received) = try listen(sb)
    defer { withExtendedLifetime(server) {} }

    let result = await sb.run("live", "click", "a5", environment: ["CUEPAD_SESSION_ID": "s1"])
    #expect(result.code == 0 && result.out == "点了 button \"登录\"\n")
    #expect(received.all == [LiveChannel.Request(session: "s1", op: .click(ref: "a5"))])

    let nobody = await sb.run("live", "click", "a5")
    #expect(nobody.code != 0 && nobody.err.contains("CUEPAD_SESSION_ID"))
    #expect(received.all.count == 1)
  }

  /// 文件只在命令行的进程里读写：截图 App 把 PNG 交回来、命令行写盘，要交的文件命令行读出内容交过去，请求里没有路径
  /// （沙箱里的 Agent 借不到 App 的权限往沙箱外写、从沙箱外读）。
  @Test func liveFilesAreReadAndWrittenByTheCommandItselfNotByPath() async throws {
    let sb = try Fixture()
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7])
    let (server, received) = try listen(sb, answer: .done("710×848，166 KB", .init(width: 710, height: 848, bytes: png.count), file: png))
    defer { withExtendedLifetime(server) {} }
    let work = sb.directory.appending(path: "work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try Data("头像".utf8).write(to: work.appending(path: "avatar.png"))

    let shot = await sb.run("live", "screenshot", "--out", "page.png", cwd: work.path, environment: ["CUEPAD_SESSION_ID": "s1"])
    #expect(shot.code == 0 && shot.out.hasSuffix("/work/page.png（710×848，166 KB）\n"), "\(shot.out)\(shot.err)")
    #expect(try Data(contentsOf: work.appending(path: "page.png")) == png)

    let sent = await sb.run("live", "upload", "a3", "avatar.png", cwd: work.path, environment: ["CUEPAD_SESSION_ID": "s1"])
    #expect(sent.code == 0, "\(sent.err)")
    let missing = await sb.run("live", "upload", "a3", "nope.png", cwd: work.path, environment: ["CUEPAD_SESSION_ID": "s1"])
    #expect(missing.code != 0 && missing.err.contains("读不到 ") && missing.err.contains("/work/nope.png"))
    #expect(received.all == [
      LiveChannel.Request(session: "s1", op: .screenshot()),
      LiveChannel.Request(session: "s1", op: .upload(ref: "a3", files: [.init(name: "avatar.png", data: Data("头像".utf8))])),
    ])
  }

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
  }
}
#endif
