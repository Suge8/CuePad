#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeTerminalTests {
    /// 权限确认与 AskUserQuestion 都弹在终端里，同时出现在 CuePad；从 CuePad 答了，终端里的这一问随之收起，工具照答案执行。
    @Test func cuePadAnswersThePermissionPromptAndTheQuestionOfATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "allowed.txt")

            let asked = Date()
            try await terminal.type("用 Bash 工具执行 touch \(touched.path) ，然后只回复 DONE")
            let permission = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(permission.kind == .known(.confirm) && permission.text.hasPrefix("允许 Claude Code 使用 Bash？"))
            try await testbed.bridge.answer(.confirmed(true), to: try #require(permission.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: asked)
            #expect(FileManager.default.fileExists(atPath: touched.path))
            #expect(testbed.bridge.session(id: session.id)?.question == nil)

            let chose = Date()
            try await terminal.type("用 AskUserQuestion 工具问我喝什么（一个单选问题，选项是 茶、咖啡），然后只回复我选的选项词")
            let question = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(question.kind == .known(.select) && question.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(question.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: chose)
            #expect(await terminal.screen.contains("→ 咖啡"))

            // 终端里每道选择题都能自己填：从 CuePad 写一个不在选项里的
            let typed = Date()
            try await terminal.type("再用 AskUserQuestion 工具问我一次喝什么（一个单选问题，选项是 茶、咖啡），然后只回复我给的回答")
            let again = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(again.allowsOther)
            try await testbed.bridge.answer(.text("果汁"), to: try #require(again.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: typed)
            #expect(await terminal.screen.contains("→ 果汁"))
        }
    }

    /// 提问按人在不在分：人不在时挂住等 CuePad 答（终端里不弹）；挂着时人回来了就放行，终端里问、CuePad 只显示；
    /// 人在时直接在终端里问，CuePad 上只显示、不能答。
    @Test func aQuestionGoesToTheTerminalWhenTheUserIsAtTheMac() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let prompt = "用 AskUserQuestion 工具问我喝什么（一个单选问题，选项是 茶、咖啡），然后只回复我选的选项词"

            try await terminal.type(prompt)
            let held = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(await !terminal.screen.contains("2. 咖啡"))
            testbed.presence.isPresent = true
            try await eventually("CuePad 上只显示") { testbed.bridge.session(id: session.id)?.question.map { $0.promptID == nil } == true }
            await #expect(throws: PiBridgeError.rejected("no_prompt")) {
                try await testbed.bridge.answer(.option("咖啡"), to: try #require(held.promptID), in: session.id)
            }
            try await eventually("终端里问") { await terminal.screen.contains("2. 咖啡") }
            let chose = Date()
            try await terminal.keys("Enter")
            try await testbed.waitForTurn(session.id, since: chose)

            try await terminal.type(prompt)
            try await eventually("又在问") { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里问") { await terminal.screen.contains("2. 咖啡") }
        }
    }

    /// MCP 服务要你填的只有一个字段的表单（Elicitation）：人不在时从 CuePad 答，答案交给 MCP 服务；
    /// 人在时终端里弹表单、CuePad 只显示，终端里答了（这里是取消）它就收起。没放行的 MCP 工具问权限，标题与终端一样写"服务 - 工具 (MCP)"。
    @Test func cuePadAnswersAnMCPFormWhileTheUserIsAway() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let config = testbed.root.appending(path: "mcp.json")
            let server = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/mcp-echo.mjs")
            let node = try #require(ExecutableLocator.standard.candidates("node").first)
            try (["mcpServers": ["cue": ["command": .string(node.path), "args": [.string(server.path)]]]] as JSONValue).data.write(to: config)
            let terminal = try await testbed.terminal(["--mcp-config", config.path, "--allowedTools", "mcp__cue__pick"])
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let prompt = "调用 mcp__cue__pick 工具（不要用别的工具），然后原样回复它返回的文字"

            let asked = Date()
            let form = try await testbed.ask(prompt, on: terminal, in: session.id)
            #expect(form.kind == .known(.select) && form.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(form.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: asked)
            #expect(await terminal.screen.contains(#""drink":"咖啡""#))

            testbed.presence.isPresent = true
            try await terminal.type(prompt)
            try await eventually("又在问") { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里弹表单") { await terminal.screen.contains("饮料") }
            let cancelled = Date()
            try await terminal.keys("Escape")  // 在终端里取消这个表单
            try await eventually("CuePad 上收起") { testbed.bridge.session(id: session.id)?.question == nil }

            testbed.presence.isPresent = false
            try await testbed.waitForTurn(session.id, since: cancelled)
            let permission = try await testbed.ask("调用 mcp__cue__echo 工具（不要用别的工具），参数 text 为 hi", on: terminal, in: session.id)
            #expect(permission.text.hasPrefix("允许 Claude Code 使用 cue - echo (MCP)？"), "\(permission.text)")
            try await testbed.bridge.answer(.confirmed(false), to: try #require(permission.promptID), in: session.id)
        }
    }

    /// 在终端里先答了：CuePad 上的这一问随之消失，之后再从 CuePad 答是"已经答过了"。
    @Test func answeringInTheTerminalFirstWithdrawsTheQuestionFromCuePad() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "here.txt")

            let permission = try await testbed.ask(
                "必须用 Bash 工具执行 touch \(touched.path) （不要用别的工具，也不要先检查），执行完只回复 DONE", on: terminal, in: session.id)
            try await eventually("终端里弹出确认") { await terminal.screen.contains("Do you want to proceed?") }
            try await terminal.keys("Enter")

            try await eventually("CuePad 上的这一问收起") { testbed.bridge.session(id: session.id)?.question == nil }
            #expect(FileManager.default.fileExists(atPath: touched.path))
            await #expect(throws: PiBridgeError.rejected("no_prompt")) {
                try await testbed.bridge.answer(.confirmed(false), to: try #require(permission.promptID), in: session.id)
            }
        }
    }
}
#endif
