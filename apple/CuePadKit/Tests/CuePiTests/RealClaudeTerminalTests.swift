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

/// CuePad 在一轮中途才启动（重启、更新都是这样）：从 `claude agents --json` 接上在跑的会话，这一轮的开始取列出它之后会话文件里读到的
/// （从索引器存下的检查点接着读）。
/// 列表请求途中可能换轮或收尾：外壳把列表扣住，期间写好会话文件，再交出"在跑"。不起 Claude Code（录像带是空的）。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.timeLimit(.minutes(5)))
struct ClaudeDiscoveryTests {
    /// 换轮：上一轮在请求途中答完、这一轮紧接着开始，回答还没写——上一轮的回答不算这一轮的（歇下先到时 Cue 不读它），这一轮的回答写下就算。
    /// 收尾：这一轮在请求途中答完——它的回答算（Cue 照样被叫醒）。
    @Test func aRoundThatChangesOrEndsWhileCuePadIsListingItIsReadFromTheSessionFile() async throws {
        let gate = try makeTempDirectory()
        let release = gate.appending(path: "release"), listing = gate.appending(path: "listing.json")
        #expect(mkfifo(release.path, 0o600) == 0)
        let wrapper = #"if [ "$1" = agents ]; then touch '\#(gate.path)/listed'; cat '\#(release.path)' >/dev/null; cat '\#(listing.path)'; else "$REAL" "$@"; fi"#
        try await ClaudeTestbed.run(installHooks: false, wrapper: wrapper) { testbed in
            try testbed.startConnected()
            let listed = gate.appending(path: "listed")
            try await eventually("列表请求发出") { FileManager.default.fileExists(atPath: listed.path) }
            // 都写在列表请求发出之后，相隔 1 毫秒（会话文件的时间戳精确到毫秒）
            let base = try #require(try FileManager.default.attributesOfItem(atPath: listed.path)[.modificationDate] as? Date)
            let at = { (step: Double) in base + step / 1000 }
            // 索引器已读过的部分接着检查点读：收尾的一轮读到时还开着，换轮的读到上一轮收尾
            let ended = try Transcript(testbed, id: UUID().uuidString.lowercased())
            try ended.user("go", at: at(1))
            try await testbed.index(ended.url)
            try ended.reply("DONE", at: at(2))
            let changed = try Transcript(testbed, id: UUID().uuidString.lowercased())
            try changed.user("first", at: at(3))
            try changed.reply("ONE", at: at(4))
            try await testbed.index(changed.url)
            try changed.user("second", at: at(5))
            // 列表里的进程要活着：起一个读标准输入的进程顶替 Claude Code，关掉输入它就退出（测试台停时等它退出）
            let stand = Process(), input = Pipe()
            stand.executableURL = URL(filePath: "/bin/cat")
            stand.standardInput = input
            try stand.run()
            defer { try? input.fileHandleForWriting.close() }
            let pid = stand.processIdentifier
            let entries: JSONValue = .array([changed, ended].map { ["pid": .number(Double(pid)), "sessionId": .string($0.id), "cwd": .string(testbed.work.path), "status": "busy"] })
            try entries.data.write(to: listing)
            close(open(release.path, O_WRONLY))

            try await eventually("两个会话接上") { testbed.bridge.sessions.count == 2 }
            let first = try #require(testbed.bridge.sessions.first { $0.sessionID == changed.id })
            let turn = try #require(first.turnStartedAt)
            let before = try testbed.transcript(first.sessionFile).recap
            #expect(before.lastReply == "ONE")
            #expect(try #require(before.answeredAt) < turn)
            try changed.reply("TWO", at: .now)
            let after = try testbed.transcript(first.sessionFile).recap
            #expect(after.lastReply == "TWO")
            #expect(try #require(after.answeredAt) >= turn)

            let second = try #require(testbed.bridge.sessions.first { $0.sessionID == ended.id })
            let recap = try testbed.transcript(second.sessionFile).recap
            #expect(recap.lastReply == "DONE")
            #expect(try #require(recap.answeredAt) >= #require(second.turnStartedAt))
        }
    }

    /// 像 Claude Code 那样逐行追加的会话文件。
    private struct Transcript {
        let id: String
        let url: URL

        init(_ testbed: ClaudeTestbed, id: String) throws {
            self.id = id
            url = ClaudeCode.sessionFile(home: testbed.config, cwd: testbed.work, sessionID: id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }

        func user(_ text: String, at time: Date) throws {
            try write(["type": "user", "message": ["role": "user", "content": .string(text)]], at: time)
        }

        func reply(_ text: String, at time: Date) throws {
            let message: JSONValue = ["role": "assistant", "model": "claude-test", "stop_reason": "end_turn", "content": [["type": "text", "text": .string(text)]]]
            try write(["type": "assistant", "message": message], at: time)
        }

        private func write(_ line: JSONValue, at time: Date) throws {
            guard case .object(var fields) = line else { return }
            fields["uuid"] = .string(UUID().uuidString)
            fields["sessionId"] = .string(id)
            fields["timestamp"] = .string(time.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONValue.object(fields).data + Data("\n".utf8))
        }
    }
}

/// 接入（装钩子）与关掉接入（删钩子）只动 settings.json 里 CuePad 的条目：不起 Claude Code，只要它的测试台（录像带是空的）。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.timeLimit(.minutes(5)))
struct ClaudeSettingsTests {
    /// 接入只把 CuePad 的钩子合并进用户自己的 settings.json；关掉接入（中间 App 搬过家、升级过也一样）后与装之前逐字节一致：
    /// 原来没有文件就没有文件，原来空着的事件数组原样留着。
    @Test(arguments: [nil, RealClaudeTerminalTests.userSettings, #"{"hooks":{"Stop":[]},"theme":"dark"}"#])
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
