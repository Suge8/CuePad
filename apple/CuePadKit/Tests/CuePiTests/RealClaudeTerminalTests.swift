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

    /// 一轮出错：按 Claude Code 报的错误类型归类成一句人话；它把错误也写成了对话里的最后一条回答，对话里只显示那一处。
    @Test func aFailedTurnIsClassifiedAndShownOnce() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal(["--model", "claude-nosuch-9"])
            let session = try await testbed.waitForSession(pid: terminal.pid)
            _ = try await testbed.bridge.send(PiMessage(text: "say hi"), to: session.id)
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
            let chose = Date()
            try await terminal.keys("Enter")
            try await testbed.waitForTurn(session.id, since: chose)

            try await terminal.type(prompt)
            try await eventually("又在问", timeout: .seconds(180)) { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里问", timeout: .seconds(30)) { await terminal.screen.contains("2. 咖啡") }
        }
    }

    /// MCP 服务要你填的只有一个字段的表单（Elicitation）：人不在时从 CuePad 答，答案交给 MCP 服务；
    /// 人在时终端里弹表单、CuePad 只显示，终端里答了（这里是取消）它就收起。没放行的 MCP 工具问权限，标题与终端一样写"服务 - 工具 (MCP)"。
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

            let asked = Date()
            let form = try await testbed.ask(prompt, on: terminal, in: session.id)
            #expect(form.kind == .known(.select) && form.options == ["茶", "咖啡"])
            try await testbed.bridge.answer(.option("咖啡"), to: try #require(form.promptID), in: session.id)
            try await testbed.waitForTurn(session.id, since: asked)
            #expect(await terminal.screen.contains(#""drink":"咖啡""#))

            testbed.presence.isPresent = true
            try await terminal.type(prompt)
            try await eventually("又在问", timeout: .seconds(180)) { testbed.bridge.session(id: session.id)?.question != nil }
            #expect(testbed.bridge.session(id: session.id)?.question?.promptID == nil)
            try await eventually("终端里弹表单", timeout: .seconds(30)) { await terminal.screen.contains("饮料") }
            let cancelled = Date()
            try await terminal.keys("Escape")  // 在终端里取消这个表单
            try await eventually("CuePad 上收起", timeout: .seconds(60)) { testbed.bridge.session(id: session.id)?.question == nil }

            testbed.presence.isPresent = false
            try await testbed.waitForTurn(session.id, since: cancelled)
            let permission = try await testbed.ask("调用 mcp__cue__echo 工具（不要用别的工具），参数 text 为 hi", on: terminal, in: session.id)
            #expect(permission.text.hasPrefix("允许 Claude Code 使用 cue - echo (MCP)？"), "\(permission.text)")
            try await testbed.bridge.answer(.confirmed(false), to: try #require(permission.promptID), in: session.id)
        }
    }

    /// 收件箱送到的话 Claude Code 一律当作"另一个会话发来的"（行里没有能改这一点的字段，实测）：正文前带一句说明是用户本人从 CuePad 发的、
    /// 直接回答不必回传；CuePad 的对话里只显示你说的那句。跳过权限确认的会话默认把收件箱的话挂起等你批准，CuePad 带上会话交给钩子的
    /// 收件箱令牌（官方给脚本的认证行），话直接送到。只看话进没进会话，不等模型回答。
    @Test func aMessageReachesATerminalSessionThatBypassesPermissionsAsTheUsersOwn() async throws {
        try await ClaudeTestbed.run(settings: #"{"skipDangerousModePermissionPrompt": true}"#) { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal(mode: "bypassPermissions")
            let session = try await testbed.waitForSession(pid: terminal.pid)

            _ = try await testbed.bridge.send(PiMessage(text: "INBOX-PROBE 只回复 OK"), to: session.id)

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

    /// 终端会话同一规则：在飞的只认 Stop 钩子带的后台任务清单，交回结果的那一轮做完才歇下一次。
    @Test func backgroundWorkKeepsATerminalSessionBusyUntilItsResultIsReportedBack() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.runtime.start()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let start = Date()
            try await terminal.type(ClaudeTestbed.backgroundWork)
            try await testbed.expectSettledOnce(session.id, since: start, reply: "BG_DONE", roster: .done)
        }
    }

    /// CuePad 在一轮中途才启动（重启、更新都是这样）：接上的这一轮开始时刻不知道，从接上的此刻算，不沿用库里上一轮的——
    /// 上一轮的回答早于它（歇下先到时 Cue 不会读到上一轮的回答），这一轮的回答不早于它（读到就算就绪，`PiSessionState.answered`）。
    @Test func aRoundAlreadyRunningWhenCuePadStartsCountsFromWhenItWasSeen() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            testbed.hooks.stop()  // CuePad 没在跑：钩子连不上，Claude Code 照常往下走
            let terminal = try await testbed.terminal()
            // 等它起好（登记了会话）再打字：之前的回车会被吞掉
            try await eventually("Claude Code 登记了这个会话", timeout: .seconds(60)) {
                FileManager.default.fileExists(atPath: testbed.config.appending(path: "sessions/\(terminal.pid).json").path)
            }
            try await terminal.type("What is 6 times 7? Reply with only the number.")
            try await eventually("上一轮答完", timeout: .seconds(120)) { testbed.transcriptFiles.contains { $0.contains(#""text":"42""#) } }
            try await terminal.type("Run the shell command sleep 20 with the Bash tool, then reply with only the word FINISHED.")
            try await eventually("这一轮在跑命令", timeout: .seconds(120)) { testbed.transcriptFiles.contains { $0.contains(#""command":"sleep 20""#) } }

            try testbed.hooks.start()
            try testbed.runtime.start()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let turn = try #require(session.turnStartedAt)
            let before = try #require(try testbed.transcript(session.sessionFile).recap.answeredAt)
            #expect(session.state.isWorking && before < turn, "\(before) \(turn)")

            try await eventually("这一轮答完歇下", timeout: .seconds(180)) {
                testbed.bridge.session(id: session.id)?.state == .settled
                    && (try? testbed.transcript(session.sessionFile))?.recap.lastReply?.contains("FINISHED") == true
            }
            let answered = try #require(try testbed.transcript(session.sessionFile).recap.answeredAt)
            #expect(testbed.bridge.session(id: session.id)?.turnStartedAt == turn && turn <= answered, "\(turn) \(answered)")
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
            try await eventually("变化记录里有这次结束") { !log.ended.isEmpty }
            #expect(log.ended.map(\.0.id) == [session.id])
        }
    }

    /// 用户在终端里打开了 CuePad 正托管着的会话：托管的进程让出（空闲就退），桥上换成终端里的那个。
    @Test func aHostedSessionYieldsWhenTheUserOpensItInTheTerminal() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
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
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.timeLimit(.minutes(5)))
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
                paths: testbed.paths, locate: { AgentTape.locator("claude") },
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
