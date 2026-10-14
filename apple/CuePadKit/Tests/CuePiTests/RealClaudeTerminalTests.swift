#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：终端里的 Claude Code（真 `claude`，tmux 里跑）接进 CuePad——经钩子出现在桥上、经收件箱收到 CuePad 发的话、
/// 等你确认时从 CuePad 作答、改名、结束；接入（装钩子）与关掉接入（删钩子）只动 settings.json 里 CuePad 的条目。
@MainActor
@Suite(.enabled(if: realClaudeAvailable && tmuxURL != nil, "需要 claude、tmux 与 ~/.pi/agent/auth.json 里的小米密钥"), .serialized, .timeLimit(.minutes(8)))
struct RealClaudeTerminalTests {
    /// 用户自己的 settings.json：别的设置、自己的一个 Stop 钩子
    nonisolated static let userSettings = """
        {
          "theme": "dark",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "true"
                  }
                ]
              }
            ]
          },
          "permissions": {
            "allow": []
          }
        }

        """

    @Test func aTerminalSessionAppearsAndReceivesCuePadsMessage() async throws {
        try await ClaudeTestbed.run(settings: Self.userSettings) { testbed in
            try testbed.runtime.start()

            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            #expect(!session.hosted && session.terminal.tmuxPane != nil && session.terminal.tty != nil)

            let delivery = UUID().uuidString
            let delivered = try await testbed.bridge.send(PiMessage(text: "只回复 PONG", deliveryID: delivery), to: session.id)
            #expect(delivered == .immediate)
            try await testbed.waitForTurn(session.id)
            let said = try testbed.transcript(session.sessionFile).messages.filter { $0.role == .known(.user) }
            #expect(said.map(\.text) == ["只回复 PONG"])
            #expect(said.first?.deliveryID == UUID(uuidString: delivery))
            await #expect(throws: PiBridgeError.unsupported) {
                try await testbed.bridge.send(PiMessage(text: "看图", images: [PiImage(mimeType: "image/png", data: redPNG)]), to: session.id)
            }
        }
    }

    /// 接入只把 CuePad 的钩子合并进用户自己的 settings.json；关掉接入（中间 App 搬过家、升级过也一样）后与装之前逐字节一致：
    /// 原来没有文件就没有文件，原来空着的对象、`hooks`、事件数组都原样留着。
    @Test(arguments: [
        nil, Self.userSettings, "{}", "{ }\n", "{\n  \"hooks\": {}\n}\n", #"{"hooks":{"Stop":[]},"theme":"dark"}"#,
        "{\n  \"hooks\": {\n    \"Stop\": [\n    ]\n  }\n}\n",
    ])
    func connectingAndDisconnectingLeavesTheUsersSettingsByteForByte(settings: String?) async throws {
        try await ClaudeTestbed.run(installHooks: false, settings: settings) { testbed in
            let file = testbed.config.appending(path: "settings.json")
            let moved = AgentIntegration(
                paths: testbed.paths, locator: ExecutableLocator(searchDirectories: [claudeURL!.deletingLastPathComponent()]),
                cuepad: testbed.root.appending(path: "Moved/CuePad.app/Contents/Helpers/cuepad"))

            try await testbed.integration.install(.claudeCode)
            #expect(await testbed.integration.status(of: .claudeCode).files == .current)
            try await moved.install(.claudeCode)
            #expect(await moved.status(of: .claudeCode).files == .current)
            try await moved.uninstall(.claudeCode)

            #expect((try? String(contentsOf: file, encoding: .utf8)) == settings)
            #expect(await moved.status(of: .claudeCode).files == .missing)
        }
    }

    /// 权限确认与 AskUserQuestion 都弹在终端里，同时出现在 CuePad；从 CuePad 答了，终端里的这一问随之收起，工具照答案执行。
    @Test func cuePadAnswersThePermissionPromptAndTheQuestionOfATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "allowed.txt")

            try await terminal.type("用 Bash 工具执行 touch \(touched.path) ，然后只回复 DONE")
            let permission = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(permission.kind == .known(.confirm) && permission.text.contains("Bash"))
            try await testbed.bridge.answer(.confirmed(true), to: try #require(permission.promptID), in: session.id)
            try await testbed.waitForTurn(session.id)
            #expect(FileManager.default.fileExists(atPath: touched.path))
            #expect(testbed.bridge.session(id: session.id)?.question == nil)

            try await terminal.type("用 AskUserQuestion 工具问我喝什么（一个单选问题，选项是 茶、咖啡），然后只回复我选的选项词")
            let question = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(question.kind == .known(.select) && question.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(question.promptID), in: session.id)
            try await testbed.waitForTurn(session.id)
            #expect(await terminal.screen.contains("→ 咖啡"))
        }
    }

    /// 提问按人在不在分：人不在时挂住等 CuePad 答（终端里不弹）；挂着时人回来了就放行，终端里问、CuePad 只显示；
    /// 人在时直接在终端里问，CuePad 上只显示、不能答。
    @Test func aQuestionGoesToTheTerminalWhenTheUserIsAtTheMac() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.runtime.start()
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
            try await eventually("终端里问", timeout: .seconds(30)) { await terminal.screen.contains("2. 咖啡") }
            try await terminal.keys("Enter")
            try await testbed.waitForTurn(session.id)

            try await terminal.type(prompt)
            try await eventually("又在问", timeout: .seconds(180)) { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里问", timeout: .seconds(30)) { await terminal.screen.contains("2. 咖啡") }
        }
    }

    /// MCP 服务要你填的只有一个字段的表单（Elicitation）：人不在时从 CuePad 答，答案交给 MCP 服务；
    /// 人在时终端里弹表单、CuePad 只显示，终端里答了（这里是拒绝）它就收起。
    @Test func cuePadAnswersAnMCPFormWhileTheUserIsAway() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.runtime.start()
            let config = testbed.root.appending(path: "mcp.json")
            let server = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/mcp-echo.mjs")
            let node = try #require(ExecutableLocator.standard.candidates("node").first)
            try (["mcpServers": ["cue": ["command": .string(node.path), "args": [.string(server.path)]]]] as JSONValue).data.write(to: config)
            let terminal = try await testbed.terminal(["--mcp-config", config.path, "--allowedTools", "mcp__cue__pick"])
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let prompt = "调用 mcp__cue__pick 工具（不要用别的工具），然后原样回复它返回的文字"

            let form = try await testbed.ask(prompt, on: terminal, in: session.id)
            #expect(form.kind == .known(.select) && form.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(form.promptID), in: session.id)
            try await testbed.waitForTurn(session.id)
            #expect(await terminal.screen.contains(#""drink":"咖啡""#))

            testbed.presence.isPresent = true
            try await terminal.type(prompt)
            try await eventually("又在问", timeout: .seconds(180)) { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里弹表单", timeout: .seconds(30)) { await terminal.screen.contains("饮料") }
            try await terminal.keys("Down")  // 到 Accept 那一行，再右移到 Decline：终端里拒绝
            try await eventually("选到按钮") { await terminal.screen.contains("❯ Accept") }
            try await terminal.keys("Right")
            try await terminal.keys("Enter")
            try await eventually("CuePad 上收起", timeout: .seconds(60)) { testbed.bridge.session(id: session.id)?.question == nil }
        }
    }

    /// 跳过权限确认的会话默认把别处送进收件箱的话挂起等你批准；CuePad 带上会话交给钩子的收件箱令牌（官方给脚本的认证行），话直接送到。
    /// 只看话进没进会话，不等模型回答。
    @Test func aMessageReachesATerminalSessionThatBypassesPermissions() async throws {
        try await ClaudeTestbed.run(settings: #"{"skipDangerousModePermissionPrompt": true}"#) { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal(mode: "bypassPermissions")
            let session = try await testbed.waitForSession(pid: terminal.pid)

            _ = try await testbed.bridge.send(PiMessage(text: "INBOX-PROBE 只回复 OK"), to: session.id)

            let file = try #require(testbed.bridge.session(id: session.id)?.sessionFile)
            try await eventually("话进了会话") {
                let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n") ?? []
                return lines.contains { JSONValue.parse(Data($0.utf8))?["type"]?.string == "user" && $0.contains("INBOX-PROBE") }
            }
            #expect(await !terminal.screen.contains("Held"))
        }
    }

    /// 在终端里先答了：CuePad 上的这一问随之消失，之后再从 CuePad 答是"已经答过了"。
    @Test func answeringInTheTerminalFirstWithdrawsTheQuestionFromCuePad() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "here.txt")

            let permission = try await testbed.ask(
                "必须用 Bash 工具执行 touch \(touched.path) （不要用别的工具，也不要先检查），执行完只回复 DONE", on: terminal, in: session.id)
            try await eventually("终端里弹出确认") { await terminal.screen.contains("Do you want to proceed?") }
            try await terminal.keys("Enter")

            try await eventually("CuePad 上的这一问收起", timeout: .seconds(120)) { testbed.bridge.session(id: session.id)?.question == nil }
            #expect(FileManager.default.fileExists(atPath: touched.path))
            await #expect(throws: PiBridgeError.rejected("no_prompt")) {
                try await testbed.bridge.answer(.confirmed(false), to: try #require(permission.promptID), in: session.id)
            }
        }
    }

    /// 改名经收件箱改到 Claude Code 自己（终端标题与会话列表里都是新名字）；结束是让它像在终端里按 Ctrl-C 那样退出。
    @Test func cuePadRenamesAndEndsATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let log = ChangeLog(testbed.bridge)

            try await testbed.bridge.configure(name: "CuePad 改的名", in: session.id)
            try await eventually("终端里显示新名字") { await terminal.screen.contains("CuePad 改的名") }
            #expect(testbed.bridge.session(id: session.id)?.displayName == "CuePad 改的名")
            await #expect(throws: PiBridgeError.unsupported) { try await testbed.bridge.abort(session.id) }

            try await testbed.bridge.end(session.id)

            #expect(testbed.session(pid: terminal.pid) == nil)
            #expect(log.ended.map(\.0.id) == [session.id])
        }
    }

    /// CuePad 启动前就开着的会话（还没触发过钩子，钩子也没装）：启动时补上桥，照样能收到 CuePad 发的话；它开着时不能在后台再接着它。
    @Test func aSessionAlreadyRunningBeforeCuePadStartsIsDiscoveredAndCannotBeResumedElsewhere() async throws {
        try await ClaudeTestbed.run(installHooks: false) { testbed in
            let terminal = try await testbed.terminal()
            try await eventually("Claude Code 登记了这个会话", timeout: .seconds(60)) {
                FileManager.default.fileExists(atPath: testbed.config.appending(path: "sessions/\(terminal.pid).json").path)
            }

            try testbed.runtime.start()
            let session = try await testbed.waitForSession(pid: terminal.pid)

            let delivery = UUID().uuidString
            _ = try await testbed.bridge.send(PiMessage(text: "只回复 HELLO", deliveryID: delivery), to: session.id)
            try await eventually("话送到了", timeout: .seconds(120)) {
                (try? testbed.transcript(session.sessionFile).messages.contains { $0.deliveryID == UUID(uuidString: delivery) }) == true
            }
            let indexed = IndexedSession(
                id: session.sessionID, path: session.sessionFile!.path, cwd: testbed.work.path, lastActivityAt: .now, agent: .claudeCode)
            await #expect(throws: AgentRuntimeError.openElsewhere) { try await testbed.runtime.resume(indexed) }
        }
    }
}
#endif
