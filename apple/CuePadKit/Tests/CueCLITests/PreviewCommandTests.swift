#if os(macOS)
import CueStore
import Foundation
import Testing

@testable import CueCLI

/// `cuepad show`：把文件作为预览放进 Agent 会话的对话。会话从环境变量 `PI_SESSION_ID` 认出（Pi 给它的每条 bash 命令都带着），
/// 认不出就报错、不猜。
@Suite struct PreviewCommandTests {
  private func page(_ sb: Sandbox, _ name: String = "demo.html", _ text: String = "<h1>登录页</h1>") throws -> String {
    let url = sb.directory.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url.path
  }

  @Test func showStoresThePreviewForTheSessionFromTheEnvironmentAndReportsIt() async throws {
    let sb = try Sandbox()
    let reply = try await sb.object(
      "show", page(sb, "demo.html", "<link rel=\"stylesheet\" href=\"a.css\">"), "--title", "登录页", environment: ["PI_SESSION_ID": "s1"])

    let stored = try #require(try await sb.store.previews(of: "s1").first)
    #expect(reply.string("id") == stored.id.uuidString.lowercased() && reply.string("title") == "登录页" && reply.string("name") == "demo.html")
    #expect(reply.string("kind") == "web" && reply["bytes"] as? Int == stored.byteCount && reply["session"] as? String == "s1")
    #expect(reply["outsideReferences"] as? [String] == ["a.css"])
  }

  @Test func aRelativePathIsReadFromTheCurrentDirectory() async throws {
    let sb = try Sandbox()
    _ = try page(sb, "rel.html")
    let result = await sb.run("show", "rel.html", environment: ["PI_SESSION_ID": "s1"])
    #expect(result.code == 0)
    #expect(try await sb.store.previews(of: "s1").map(\.name) == ["rel.html"])
  }

  @Test func withoutASessionInTheEnvironmentItRefusesAndSaysWhy() async throws {
    let sb = try Sandbox()
    let result = await sb.run("show", try page(sb))
    #expect(result.code != 0 && result.err.contains("PI_SESSION_ID"))
    let blank = await sb.run("show", try page(sb), environment: ["PI_SESSION_ID": ""])
    #expect(blank.code != 0 && blank.err.contains("PI_SESSION_ID"))
    #expect(try await sb.store.previews(of: "").isEmpty)
  }

  @Test func showRefusesWhatCannotBePreviewedWithAReasonAndExitCode() async throws {
    let sb = try Sandbox()
    let env = ["PI_SESSION_ID": "s1"]
    let missing = await sb.run("show", sb.directory.appending(path: "nope.html").path, environment: env)
    #expect(missing.code != 0 && missing.err.contains("nope.html"))
    let archive = await sb.run("show", try page(sb, "a.zip", "zip"), environment: env)
    #expect(archive.code != 0 && archive.err.contains("zip"))
    #expect(try await sb.store.previews(of: "s1").isEmpty)
  }

  @Test func helpIsTheDocumentation() async throws {
    let sb = try Sandbox()
    let help = await sb.run("show", "--help")
    #expect(help.code == 0 && help.out.contains("--title") && help.out.contains("HTML") && help.out.contains("20 MB") && help.out.contains("单个"))
    #expect(!help.out.contains("--session"))
    #expect(await sb.run("--help").out.contains("show"))
  }
}
#endif
