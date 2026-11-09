#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

@MainActor
@Suite(RealAgents.taped(.claudeCode), .enabled(if: tmuxURL != nil, "要 tmux（断言的是 tmux 里真终端界面的输出与按键）"))
struct RealClaudeTerminalTests {
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
            try testbed.startConnected()

            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            #expect(!session.hosted && session.terminal.tmuxPane != nil && session.terminal.tty != nil)

            let delivery = UUID().uuidString
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 PONG", deliveryID: delivery), to: session.id)
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)  // 一轮歇下时会话文件可能还没写完
            let said = try testbed.transcript(testbed.bridge.session(id: session.id)?.sessionFile).messages.filter { $0.role == .known(.user) }
            #expect(said.map(\.text) == ["只回复 PONG"])
            #expect(said.first?.deliveryID == UUID(uuidString: delivery))
            await #expect(throws: PiBridgeError.unsupported) {
                try await testbed.bridge.send(PiMessage(text: "看图", images: [PiImage(mimeType: "image/png", data: redPNG)]), to: session.id)
            }
        }
    }

    @Test func aFailedTurnIsClassified() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            testbed.model.on({ $0.model == "claude-nosuch-9" }) { _ in .fail("model: claude-nosuch-9", status: 404) }
            let terminal = try await testbed.terminal(["--model", "claude-nosuch-9"])
            let session = try await testbed.waitForSession(pid: terminal.pid)
            try await testbed.bridge.send(PiMessage(text: "say hi"), to: session.id)
            @MainActor func reply() -> String? { (try? testbed.transcript(session.sessionFile))?.messages.last { $0.role == .known(.pi) }?.text }
            try await eventually("这一轮出错、那句原话进了对话") {
                testbed.bridge.session(id: session.id)?.state == .error && reply() != nil
            }
            let detail = try #require(testbed.bridge.session(id: session.id)?.detail)
            #expect(detail.hasPrefix("模型不存在或没有权限"), "\(detail)")
            #expect(testbed.bridge.session(id: session.id)?.failure == .other)
        }
    }

    /// 收件箱送到的话 Claude Code 一律当作"另一个会话发来的"（行里没有能改这一点的字段，实测）：正文前带一句说明是用户本人从 CuePad 发的、
    /// 直接回答不必回传；CuePad 的对话里只显示你说的那句。跳过权限确认的会话默认把收件箱的话挂起等你批准，CuePad 带上会话交给钩子的
    /// 收件箱令牌（官方给脚本的认证行），话直接送到。只看话进没进会话，不等模型回答。
    @Test func aMessageReachesATerminalSessionThatBypassesPermissionsAsTheUsersOwn() async throws {
        try await ClaudeTestbed.run(settings: #"{"skipDangerousModePermissionPrompt": true}"#) { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal(mode: "bypassPermissions")
            let session = try await testbed.waitForSession(pid: terminal.pid)

            try await testbed.bridge.send(PiMessage(text: "INBOX-PROBE 只回复 OK"), to: session.id)

            let file = try #require(testbed.bridge.session(id: session.id)?.sessionFile)
            var sent: Substring?
            try await eventually("话进了会话") {
                let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n") ?? []
                sent = lines.first { JSONValue.parse(Data($0.utf8))?["type"]?.string == "user" && $0.contains("INBOX-PROBE") }
                return sent != nil
            }
            #expect(sent?.contains("CuePad") == true, "正文前说明是用户本人从 CuePad 发的")
            #expect(await !terminal.screen.contains("Held"))
            let said = try testbed.transcript(file).messages.filter { $0.role == .known(.user) }.map(\.text)
            #expect(said == ["INBOX-PROBE 只回复 OK"])
            #expect(testbed.bridge.session(id: session.id)?.firstMessage == "INBOX-PROBE 只回复 OK", "标题与回复框占位里没有给模型看的说明")
        }
    }

    /// 照原因在终端里按 Esc：Claude Code 不跑钩子，会话照会话文件里的中断标记歇下（已停止）。
    @Test func aMessageWhileBusyIsRefusedWithTheReason() async throws {
        try await ClaudeTestbed.run(settings: #"{"skipDangerousModePermissionPrompt": true}"#) { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal(mode: "bypassPermissions")
            let session = try await testbed.waitForSession(pid: terminal.pid)

            testbed.on("SLEEP-RUN") { $0.step == 0 ? .call("Bash", ["command": #"python3 -c "import time; time.sleep(100)""#, "description": "slow"]) : .say("ZEBRA") }
            testbed.on("只回复 MANGO", .say("MANGO"))
            try await testbed.bridge.send(PiMessage(text: "SLEEP-RUN"), to: session.id)
            try await testbed.waitOnScreen("在跑命令", on: terminal, in: session.id) { testbed.bridge.session(id: session.id)?.detail?.contains("time.sleep(100)") == true }
            await #expect(throws: PiBridgeError.rejected("failed: 终端里的 Claude Code 在跑，CuePad 打断不了它：在终端里按 Esc，或等它做完再说")) {
                try await testbed.bridge.send(PiMessage(text: "只回复 MANGO"), to: session.id)
            }
            // 钩子报"在跑"时，会话文件可能还没写到盘上（Claude Code 的写队列每 100 毫秒才刷一次）：先等这一轮的话落盘再看
            try await eventually("SLEEP-RUN 落盘") { (try? testbed.transcript(session.sessionFile))?.messages.contains { $0.text.contains("SLEEP-RUN") } == true }
            #expect(try !testbed.transcript(session.sessionFile).messages.contains { $0.text.contains("MANGO") })

            try await terminal.keys("Escape")
            try await eventually("按 Esc 后歇下") { testbed.bridge.session(id: session.id)?.state == .settled }
            #expect(try testbed.transcript(session.sessionFile).messages.last?.text == PiNotice.stopped.rawValue)
            let delivery = UUID()
            try await testbed.bridge.send(PiMessage(text: "只回复 MANGO", deliveryID: delivery.uuidString), to: session.id)
            try await eventually("话送到了") {
                (try? testbed.transcript(session.sessionFile).messages.contains { $0.deliveryID == delivery }) == true
            }
        }
    }

    @Test func backgroundWorkKeepsATerminalSessionBusyUntilItsResultIsReportedBack() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            testbed.playBackgroundWork()
            let start = Date()
            try await terminal.type(ClaudeTestbed.backgroundWork)
            try await testbed.expectSettledOnce(session.id, since: start, reply: "BG_DONE", roster: .done)
        }
    }

    @Test func cuePadRenamesAndEndsATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let log = ChangeLog(testbed.bridge)

            try await testbed.bridge.configure(PiConfig(name: "CuePad 改的名"), in: session.id)
            try await eventually("终端里显示新名字") { await terminal.screen.contains("CuePad 改的名") }
            #expect(testbed.bridge.session(id: session.id)?.displayName == "CuePad 改的名")
            await #expect(throws: PiBridgeError.unsupported) { try await testbed.bridge.abort(session.id) }

            try await testbed.bridge.end(session.id)

            #expect(testbed.session(pid: terminal.pid) == nil)
            try await eventually("变化记录里有这次结束") { !log.ended.isEmpty }
            #expect(log.ended.map(\.0.id) == [session.id])
        }
    }

    @Test func aHostedSessionYieldsWhenTheUserOpensItInTheTerminal() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(testbed.bridge.session(id: id)).sessionID
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: start)
            let log = ChangeLog(testbed.bridge)

            let terminal = try await testbed.terminal(["--resume", sessionID])

            let opened = try await testbed.waitForSession(pid: terminal.pid)
            #expect(opened.sessionID == sessionID && !opened.hosted)
            try await eventually("托管的让出") { log.ended.map(\.0.id) == [id] }
        }
    }

    @Test func aSessionAlreadyRunningBeforeCuePadStartsIsDiscoveredAndCannotBeResumedElsewhere() async throws {
        try await ClaudeTestbed.run(installHooks: false) { testbed in
            let terminal = try await testbed.terminal()
            try await eventually("Claude Code 登记了这个会话") {
                FileManager.default.fileExists(atPath: testbed.config.appending(path: "sessions/\(terminal.pid).json").path)
            }

            try testbed.startConnected()
            let session = try await testbed.waitForSession(pid: terminal.pid)

            let delivery = UUID().uuidString
            try await testbed.bridge.send(PiMessage(text: "只回复 HELLO", deliveryID: delivery), to: session.id)
            try await eventually("话送到了") {
                (try? testbed.transcript(session.sessionFile).messages.contains { $0.deliveryID == UUID(uuidString: delivery) }) == true
            }
            let indexed = IndexedSession(
                id: session.sessionID, path: session.sessionFile!.path, cwd: testbed.work.path, lastActivityAt: .now, agent: .claudeCode)
            await #expect(throws: AgentRuntimeError.openElsewhere) { try await testbed.runtime.resume(indexed) }
        }
    }
}
#endif
