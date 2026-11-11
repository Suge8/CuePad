#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

private let drinks: [String: any Sendable] = [
    "questions": [["question": "喝什么？", "header": "饮料", "multiSelect": false,
                   "options": [["label": "茶", "description": "tea"], ["label": "咖啡", "description": "coffee"]]] as [String: any Sendable]],
]

extension RealClaudeTerminalTests {
    private func touching(_ testbed: ClaudeTestbed, _ tag: String, _ file: URL) {
        testbed.on(tag) { $0.step == 0 ? .call("Bash", ["command": "touch \(file.path)", "description": "touch"]) : .say("DONE") }
    }

    /// 允许与拒绝都从桥上答：文件在不在，和模型下一次请求带回的工具结果两边对得上。
    @Test(arguments: [true, false]) func cuePadAnswersThePermissionPromptOfATerminalSession(allow: Bool) async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "allowed.txt")
            touching(testbed, "TOUCH-FILE", touched)

            let asked = Date()
            try await terminal.type("TOUCH-FILE")
            let permission = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(permission.kind == .known(.confirm) && permission.text.hasPrefix("允许 Claude Code 使用 Bash？"))
            #expect(!FileManager.default.fileExists(atPath: touched.path))
            try await testbed.bridge.answer(.confirmed(allow), to: try #require(permission.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: asked)
            #expect(FileManager.default.fileExists(atPath: touched.path) == allow)
            #expect(testbed.bridge.session(id: session.id)?.question == nil)
            let result = try #require(testbed.model.requests.last { $0.prompt.contains("TOUCH-FILE") && $0.step == 1 }?.results.last)
            #expect(result.contains("拒绝") == !allow, "工具结果：\(result)")
        }
    }

    @Test func cuePadAnswersTheQuestionOfATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            testbed.on("ASK-DRINK") { $0.step == 0 ? .call("AskUserQuestion", drinks) : .say($0.results.last ?? "") }

            let chose = Date()
            try await terminal.type("ASK-DRINK")
            let question = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(question.kind == .known(.select) && question.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(question.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: chose)
            try await testbed.waitOnScreen("终端里画出答案", on: terminal, in: session.id) { await terminal.screen.contains("→ 咖啡") }
            #expect(testbed.model.requests.last { $0.prompt.contains("ASK-DRINK") && $0.step == 1 }?.results.last?.contains("咖啡") == true)

            let typed = Date()
            try await terminal.type("ASK-DRINK again")
            let again = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(again.allowsOther)
            try await testbed.bridge.answer(.text("果汁"), to: try #require(again.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: typed)
            try await testbed.waitOnScreen("终端里画出答案", on: terminal, in: session.id) { await terminal.screen.contains("→ 果汁") }
        }
    }

    @Test func aQuestionGoesToTheTerminalWhenTheUserIsAtTheMac() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            testbed.on("ASK-DRINK") { $0.step == 0 ? .call("AskUserQuestion", drinks) : .say($0.results.last ?? "") }

            try await terminal.type("ASK-DRINK")
            let held = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(await !terminal.screen.contains("2. 咖啡"))
            testbed.presence.isPresent = true
            try await eventually("CuePad 上只显示") { testbed.bridge.session(id: session.id)?.question.map { $0.promptID == nil } == true }
            await #expect(throws: BridgeError.rejected("no_prompt")) {
                try await testbed.bridge.answer(.option("咖啡"), to: try #require(held.promptID), in: session.id)
            }
            try await eventually("终端里问") { await terminal.screen.contains("2. 咖啡") }
            let chose = Date()
            try await terminal.press("Enter", on: "2. 咖啡") { testbed.bridge.session(id: session.id)?.question == nil }
            try await testbed.waitForTurn(session.id, since: chose)

            try await terminal.type("ASK-DRINK again")
            try await eventually("又在问") { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里问") { await terminal.screen.contains("2. 咖啡") }
        }
    }

    /// 没放行的 MCP 工具问权限，标题与终端一样写"服务 - 工具 (MCP)"。
    @Test func cuePadAnswersAnMCPFormWhileTheUserIsAway() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let config = testbed.root.appending(path: "mcp.json")
            let server = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/mcp-echo.mjs")
            let node = try #require(ExecutableLocator.standard.candidates("node").first)
            try (["mcpServers": ["cue": ["command": .string(node.path), "args": [.string(server.path)]]]] as JSONValue).data.write(to: config)
            let terminal = try await testbed.terminal(["--mcp-config", config.path, "--allowedTools", "mcp__cue__pick"])
            let session = try await testbed.waitForSession(pid: terminal.pid)
            testbed.on("MCP-PICK") { $0.step == 0 ? .call("mcp__cue__pick", [:]) : .say($0.results.last ?? "") }
            testbed.on("MCP-ECHO") { $0.step == 0 ? .call("mcp__cue__echo", ["text": "hi"]) : .say("ECHOED") }

            let asked = Date()
            try await terminal.type("MCP-PICK")
            let form = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(form.kind == .known(.select) && form.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(form.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: asked)
            try await testbed.waitOnScreen("终端里画出答案", on: terminal, in: session.id) { await terminal.screen.contains(#""drink":"咖啡""#) }

            testbed.presence.isPresent = true
            try await terminal.type("MCP-PICK")
            try await eventually("又在问") { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里弹表单") { await terminal.screen.contains("饮料") }
            let cancelled = Date()
            try await terminal.press("Escape", on: "饮料") { testbed.bridge.session(id: session.id)?.question == nil }  // 在终端里取消这个表单

            testbed.presence.isPresent = false
            try await testbed.waitForTurn(session.id, since: cancelled)
            try await terminal.type("MCP-ECHO")
            let permission = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(permission.text.hasPrefix("允许 Claude Code 使用 cue - echo (MCP)？"), "\(permission.text)")
            try await testbed.bridge.answer(.confirmed(false), to: try #require(permission.promptID), in: session.id)
        }
    }

    @Test func answeringInTheTerminalFirstWithdrawsTheQuestionFromCuePad() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "here.txt")
            touching(testbed, "HERE-TOUCH", touched)

            try await terminal.type("HERE-TOUCH")
            let permission = try await testbed.waitForQuestion(session.id, on: terminal)
            try await eventually("终端里弹出确认") { await terminal.screen.contains("Do you want to proceed?") }
            try await terminal.press("Enter", on: "Do you want to proceed?") { testbed.bridge.session(id: session.id)?.question == nil }
            #expect(FileManager.default.fileExists(atPath: touched.path))
            await #expect(throws: BridgeError.rejected("no_prompt")) {
                try await testbed.bridge.answer(.confirmed(false), to: try #require(permission.promptID), in: session.id)
            }
        }
    }
}
#endif
