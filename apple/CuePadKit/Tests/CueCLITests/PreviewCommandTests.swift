#if os(macOS)
import CueStore
import Foundation
import Testing

@testable import CueCLI

/// `cuepad show`：把文件作为预览放进某个 Pi 会话（与 Pi 里的 cuepad_show 工具是同一个 Store 接口的两个入口）。
@Suite struct PreviewCommandTests {
  private func page(_ sb: Sandbox, _ name: String = "demo.html", _ text: String = "<h1>登录页</h1>") throws -> String {
    let url = sb.directory.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url.path
  }

  @Test func showStoresThePreviewForTheSessionAndReportsIt() async throws {
    let sb = try Sandbox()
    let reply = try await sb.object("show", page(sb, "demo.html", "<link rel=\"stylesheet\" href=\"a.css\">"), "--session", "s1", "--title", "登录页")

    let stored = try #require(try await sb.store.previews(of: "s1").first)
    #expect(reply.string("id") == stored.id.uuidString.lowercased() && reply.string("title") == "登录页" && reply.string("name") == "demo.html")
    #expect(reply.string("kind") == "web" && reply["bytes"] as? Int == stored.byteCount && reply["session"] as? String == "s1")
    #expect(reply["outsideReferences"] as? [String] == ["a.css"])
  }

  @Test func showRefusesWhatCannotBePreviewedWithAReasonAndExitCode() async throws {
    let sb = try Sandbox()
    let missing = await sb.run("show", sb.directory.appending(path: "nope.html").path, "--session", "s1")
    #expect(missing.code != 0 && missing.err.contains("nope.html"))
    let archive = await sb.run("show", try page(sb, "a.zip", "zip"), "--session", "s1")
    #expect(archive.code != 0 && archive.err.contains("zip"))
    let noSession = await sb.run("show", try page(sb))
    #expect(noSession.code != 0 && noSession.err.contains("--session"))
    #expect(try await sb.store.previews(of: "s1").isEmpty)
  }

  @Test func helpIsTheDocumentation() async throws {
    let sb = try Sandbox()
    let help = await sb.run("show", "--help")
    #expect(help.code == 0 && help.out.contains("--session") && help.out.contains("HTML") && help.out.contains("20 MB"))
    #expect(await sb.run("--help").out.contains("show"))
  }
}
#endif
