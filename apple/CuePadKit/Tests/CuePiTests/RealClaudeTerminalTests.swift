#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：终端里的 Claude Code（真 `claude`，tmux 里跑）接进 CuePad——经钩子出现在桥上、经收件箱收到 CuePad 发的话、
/// 等你确认时从 CuePad 作答、后台工作交回后才歇下、改名、结束。
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
            try testbed.startConnected()

            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            #expect(!session.hosted && session.terminal.tmuxPane != nil && session.terminal.tty != nil)

            let delivery = UUID().uuidString
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 PONG", deliveryID: delivery), to: session.id)
            try await testbed.waitForTurn(session.id, since: start)
            let said = try testbed.transcript(session.sessionFile).messages.filter { $0.role == .known(.user) }
            #expect(said.map(\.text) == ["只回复 PONG"])
            #expect(said.first?.deliveryID == UUID(uuidString: delivery))
            await #expect(throws: PiBridgeError.unsupported) {
                try await testbed.bridge.send(PiMessage(text: "看图", images: [PiImage(mimeType: "image/png", data: redPNG)]), to: session.id)
            }
        }
    }

    /// 一轮出错：按 Claude Code 报的错误类型归类成一句人话；它把错误也写成了对话里的最后一条回答，对话里只显示那一处。
    @Test func aFailedTurnIsClassifiedAndShownOnce() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal(["--model", "claude-nosuch-9"])
            let session = try await testbed.waitForSession(pid: terminal.pid)
            try await testbed.bridge.send(PiMessage(text: "say hi"), to: session.id)
            @MainActor func reply() throws -> String? { try testbed.transcript(session.sessionFile).messages.last { $0.role == .known(.pi) }?.text }
            try await eventually("这一轮出错、那句原话进了对话", timeout: .seconds(90)) {
                try testbed.bridge.session(id: session.id)?.state == .error && reply() != nil
            }
            let detail = try #require(testbed.bridge.session(id: session.id)?.detail)
            #expect(detail.hasPrefix("模型不存在或没有权限"), "\(detail)")
            let reply = try reply()
            #expect(PiErrorSummary.echoes(reply, line: detail), "\(String(describing: reply)) / \(detail)")
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

    /// 在跑时从 CuePad 说话：CuePad 打断不了终端里的 Claude Code（`AgentCapabilities.speakBlocked`），拒收并说明原因，话不进会话。
    /// 照原因在终端里按 Esc：Claude Code 不跑钩子，会话照会话文件里的中断标记歇下（已停止），之后从 CuePad 说的话送得到。
    @Test func aMessageWhileBusyIsRefusedWithTheReason() async throws {
        try await ClaudeTestbed.run(settings: #"{"skipDangerousModePermissionPrompt": true}"#) { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal(mode: "bypassPermissions")
            let session = try await testbed.waitForSession(pid: terminal.pid)

            try await testbed.bridge.send(PiMessage(text: "用 Bash 工具在前台执行 `ping -c 120 127.0.0.1`，然后只回复 ZEBRA"), to: session.id)
            try await eventually("在跑命令", timeout: .seconds(120)) { testbed.bridge.session(id: session.id)?.detail?.contains("ping -c 120") == true }
            await #expect(throws: PiBridgeError.rejected("failed: 终端里的 Claude Code 在跑，CuePad 打断不了它：在终端里按 Esc，或等它做完再说")) {
                try await testbed.bridge.send(PiMessage(text: "只回复 MANGO"), to: session.id)
            }
            #expect(try !testbed.transcript(session.sessionFile).messages.contains { $0.text.contains("MANGO") })

            try await terminal.keys("Escape")
            try await eventually("按 Esc 后歇下", timeout: .seconds(30)) { testbed.bridge.session(id: session.id)?.state == .settled }
            #expect(try testbed.transcript(session.sessionFile).messages.last?.text == PiNotice.stopped.rawValue)
            let delivery = UUID()
            try await testbed.bridge.send(PiMessage(text: "只回复 MANGO", deliveryID: delivery.uuidString), to: session.id)
            try await eventually("话送到了", timeout: .seconds(60)) {
                (try? testbed.transcript(session.sessionFile).messages.contains { $0.deliveryID == delivery }) == true
            }
        }
    }

    /// 终端会话同一规则：在飞的只认 Stop 钩子带的后台任务清单，交回结果的那一轮做完才歇下一次。
    @Test func backgroundWorkKeepsATerminalSessionBusyUntilItsResultIsReportedBack() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let start = Date()
            try await terminal.type(ClaudeTestbed.backgroundWork)
            try await testbed.expectSettledOnce(session.id, since: start, reply: "BG_DONE", roster: .done)
        }
    }

    /// 改名经收件箱改到 Claude Code 自己（终端标题与会话列表里都是新名字）；结束是让它像在终端里按 Ctrl-C 那样退出。
    @Test func cuePadRenamesAndEndsATerminalSession() async throws {
        try await ClaudeTestbed.run() { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let log = ChangeLog(testbed.bridge)

            try await testbed.bridge.configure(name: "CuePad 改的名", in: session.id)
            try await eventually("终端里显示新名字") { await terminal.screen.contains("CuePad 改的名") }
            #expect(testbed.bridge.session(id: session.id)?.displayName == "CuePad 改的名")
            await #expect(throws: PiBridgeError.unsupported) { try await testbed.bridge.abort(session.id) }

            try await testbed.bridge.end(session.id)

            #expect(testbed.session(pid: terminal.pid) == nil)
            try await eventually("变化记录里有这次结束") { !log.ended.isEmpty }
            #expect(log.ended.map(\.0.id) == [session.id])
        }
    }

    /// 用户在终端里打开了 CuePad 正托管着的会话：托管的进程让出（空闲就退），桥上换成终端里的那个。
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

            try testbed.startConnected()
            let session = try await testbed.waitForSession(pid: terminal.pid)

            let delivery = UUID().uuidString
            try await testbed.bridge.send(PiMessage(text: "只回复 HELLO", deliveryID: delivery), to: session.id)
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
