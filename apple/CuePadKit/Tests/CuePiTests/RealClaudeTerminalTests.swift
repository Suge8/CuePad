#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：终端里的 Claude Code（真 `claude`，tmux 里跑）接进 CuePad——经钩子出现在桥上、经收件箱收到 CuePad 发的话、
/// 等你确认时从 CuePad 作答、改名、结束。
@MainActor
@Suite(RealAgents.live(.claudeCode, "断言的是 tmux 里真终端界面的输出与按键"), .enabled(if: tmuxURL != nil, "要 tmux"), .serialized, .timeLimit(.minutes(8)))
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
            let start = Date()
            let delivered = try await testbed.bridge.send(PiMessage(text: "只回复 PONG", deliveryID: delivery), to: session.id)
            #expect(delivered == .immediate)
            try await testbed.waitForTurn(session.id, since: start)
            let said = try testbed.transcript(session.sessionFile).messages.filter { $0.role == .known(.user) }
            #expect(said.map(\.text) == ["只回复 PONG"])
            #expect(said.first?.deliveryID == UUID(uuidString: delivery))
            await #expect(throws: PiBridgeError.unsupported) {
                try await testbed.bridge.send(PiMessage(text: "看图", images: [PiImage(mimeType: "image/png", data: redPNG)]), to: session.id)
            }
        }
    }

    /// 权限确认与 AskUserQuestion 都弹在终端里，同时出现在 CuePad；从 CuePad 答了，终端里的这一问随之收起，工具照答案执行。
    @Test func cuePadAnswersThePermissionPromptAndTheQuestionOfATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let touched = testbed.work.appending(path: "allowed.txt")

            let asked = Date()
            try await terminal.type("用 Bash 工具执行 touch \(touched.path) ，然后只回复 DONE")
            let permission = try await testbed.waitForQuestion(session.id, on: terminal)
            #expect(permission.kind == .known(.confirm) && permission.text.contains("Bash"))
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

            try await testbed.runtime.end(session.id)

            #expect(testbed.session(pid: terminal.pid) == nil)
            #expect(log.ended.map(\.0.id) == [session.id])
        }
    }

    /// 用户在终端里打开了 CuePad 正托管着的会话：托管的进程让出（空闲就退），桥上换成终端里的那个。
    @Test func aHostedSessionYieldsWhenTheUserOpensItInTheTerminal() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t")
            let sessionID = try #require(testbed.bridge.session(id: id)).sessionID
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: start)
            let log = ChangeLog(testbed.bridge)

            let terminal = try await testbed.terminal(["--resume", sessionID])

            let opened = try await testbed.waitForSession(pid: terminal.pid)
            #expect(opened.sessionID == sessionID && !opened.hosted)
            try await eventually("托管的让出", timeout: .seconds(60)) { log.ended.map(\.0.id) == [id] }
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

/// 接入（装钩子）与关掉接入（删钩子）只动 settings.json 里 CuePad 的条目：不起 Claude Code，只要它的测试台（录像带是空的）。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode))
struct ClaudeSettingsTests {
    /// 接入只把 CuePad 的钩子合并进用户自己的 settings.json；关掉接入（中间 App 搬过家、升级过也一样）后与装之前逐字节一致：
    /// 原来没有文件就没有文件，原来空着的对象、`hooks`、事件数组都原样留着。
    @Test(arguments: [
        nil, RealClaudeTerminalTests.userSettings, "{}", "{ }\n", "{\n  \"hooks\": {}\n}\n", #"{"hooks":{"Stop":[]},"theme":"dark"}"#,
        "{\n  \"hooks\": {\n    \"Stop\": [\n    ]\n  }\n}\n",
    ])
    func connectingAndDisconnectingLeavesTheUsersSettingsByteForByte(settings: String?) async throws {
        AgentTape.variant(settings.map { "\($0.count)" } ?? "none")
        try await ClaudeTestbed.run(installHooks: false, settings: settings) { testbed in
            let file = testbed.config.appending(path: "settings.json")
            let moved = AgentIntegration(
                paths: testbed.paths, locator: AgentTape.locator("claude"),
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
}
#endif
