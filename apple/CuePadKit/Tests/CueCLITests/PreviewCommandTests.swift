#if os(macOS)
import CueStore
import Foundation
import Testing

@testable import CueCLI

/// `cuepad show`：把文件作为预览放进 Agent 会话的对话。会话从 Agent 给每条命令带的环境变量认出（如 Pi 的 `PI_SESSION_ID`），
/// 认不出就报错、不猜。
@Suite struct PreviewCommandTests {
  private func page(_ sb: Sandbox, _ name: String = "demo.html", _ text: String = "<h1>登录页</h1>") throws -> String {
    let url = sb.directory.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url.path
  }

  /// 一次给几个文件：按给的顺序存成同一次（对话里一张卡），每个文件一个 --title（按先后），每个文件一项报告。
  @Test func showStoresTheFilesTogetherForTheSessionFromTheEnvironmentAndReportsEach() async throws {
    let sb = try Sandbox()
    // .ts 是 TypeScript（系统认作视频流）：按文本发
    let files = [try page(sb, "demo.html", "<link rel=\"stylesheet\" href=\"a.css\">"), try page(sb, "beep.m4a", "m4a"), try page(sb, "notes.docx", "docx"), try page(sb, "app.ts", "let a = 1")]
    let titles = ["登录页：首屏", "提示音", "需求文稿", "入口"]
    let reply = try array(try await sb.jsonValue(["show"] + files + titles.flatMap { ["--title", $0] }, environment: ["PI_SESSION_ID": "s1"]))

    let stored = try await sb.store.previews(of: "s1")
    #expect(stored.map(\.name) == ["demo.html", "beep.m4a", "notes.docx", "app.ts"] && Set(stored.map(\.createdAt)).count == 1)
    #expect(reply.map { $0.string("id") } == stored.map { $0.id.uuidString.lowercased() })
    #expect(reply.map { $0.string("kind") } == ["web", "audio", "document", "text"] && reply.allSatisfy { $0.string("session") == "s1" })
    #expect(reply.map { $0.string("title") } == titles && stored.map(\.title) == titles)
    #expect(reply[0]["bytes"] as? Int == stored[0].byteCount && reply[0]["outsideReferences"] as? [String] == ["a.css"])
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
    // 每个文件都要一句标题：少了不收
    let untitled = await sb.run("show", try page(sb), try page(sb, "b.html"), "--title", "登录页", environment: env)
    #expect(untitled.code != 0 && untitled.err.contains("--title"))
    let repeated = await sb.run("show", try page(sb), try page(sb, "b.html"), "--title", "登录页", "--title", "登录页", environment: env)
    #expect(repeated.code != 0 && repeated.err.contains("各不相同"))
    let missing = await sb.run("show", sb.directory.appending(path: "nope.html").path, "--title", "x", environment: env)
    #expect(missing.code != 0 && missing.err.contains("nope.html"))
    let archive = await sb.run("show", try page(sb, "a.zip", "zip"), "--title", "x", environment: env)
    #expect(archive.code != 0 && archive.err.contains("zip"))
    // 压缩的 SVG 预览里显示不了：不收，可发列表里也不列
    let compressed = await sb.run("show", try page(sb, "a.svgz", "svgz"), "--title", "x", environment: env)
    #expect(compressed.code != 0 && compressed.err.contains(".svgz") && !compressed.err.contains("、svgz"))
    #expect(try await sb.store.previews(of: "s1").isEmpty)
  }

}
#endif
