#if os(macOS)
import AppKit
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// Cue 的真模型评测：给改提示词（`CuePrompt`、`CueTools` 的说明、`CueEnvelope`）做前后对比。只在 `CUEPAD_CUE_EVAL=1` 时跑，跑法见 docs/verify.md「Cue 评测」。
/// 大脑是真的 Claude Code（同用户的 Cue：默认 opus、medium），系统提示、工具与信封全走生产路径（`CueKeeper` 起班次）；
/// 其余沿用 `CueHostTests.Rig`：真 `cuepad mcp`、隔离库、执行器开的会话由假扩展扮演。每个场景先等刚启用那一轮做完，
/// 再直接在库与假会话上摆好状态，让 Cue 被你的话或会话的动静自然叫醒，只评被叫醒的那一轮。
/// 每个场景把信封、工具调用与结果、Cue 写的消息、判定写进 `CUEPAD_CUE_EVAL_OUT`（缺省 /tmp/cue-eval/latest）的一个 .md，summary.md 汇总。
nonisolated private let environment = ProcessInfo.processInfo.environment
private let output = URL(filePath: environment["CUEPAD_CUE_EVAL_OUT"] ?? "/tmp/cue-eval/latest", directoryHint: .isDirectory)

@Suite(.enabled(if: environment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(10)))
struct CueEvalTests {
    private static let request = """
        给演示项目的登录页加一个「忘记密码」：点了之后让用户填邮箱，发一封重置密码的邮件。几条要求：重置链接 30 分钟内有效、只能用一次；\
        邮件沿用现在注册验证邮件的模板样式；同一个邮箱一分钟内最多发一次，防止被刷；不管邮箱存不存在都提示「如果这个邮箱注册过，你会收到一封邮件」，别泄露用户是否存在。
        """
    private static let title = "登录页加忘记密码"
    private static let body = """
        登录页加「忘记密码」入口：填邮箱后发重置密码邮件。
        要求：重置链接 30 分钟内有效、只能用一次；邮件沿用注册验证邮件的模板；同一邮箱 1 分钟内最多发一次；不论邮箱是否存在都提示「如果这个邮箱注册过，你会收到一封邮件」。
        做完的标准：跑过项目已有的测试与 lint 并贴出输出；改前改后的登录页截图发到手机。推送前先停下来问。
        """

    @Test func a新活派发() async throws {
        try await CueEval.run("a-新活派发", expect: "建一个任务（标题不超宽、一次建成）、放进演示、开工，回复一两句；不发等你、不问用户") { eval in
            let rig = eval.rig
            let site = try await rig.store.createProject(name: "官网", color: "green")
            try await rig.store.setDirectory(rig.app.directory.appending(path: "site").path, for: site.id)
            try await eval.trigger { try await rig.say(Self.request) }
            let added = eval.calls("task", "add")
            let tasks = try await rig.store.cueBoard().tasks.map(\.task)
            let demo = try await rig.store.projects().first { $0.name == "演示" }
            let reply = try await eval.reply()
            return [
                Check("只建了一个任务", tasks.count == 1),
                Check("一次建成（add 没被退回）", !added.isEmpty && added.allSatisfy { !$0.call.failed }),
                Check("标题宽不过 \(CueName.limit)", tasks.allSatisfy { CueName.width($0.heading) <= CueName.limit }),
                Check("放进演示项目", tasks.first?.projectID == demo?.id),
                Check("开工（开出了会话）", rig.app.host.calls.contains { if case .open = $0 { true } else { false } }),
                Check("回复一两句", reply.map { sentences($0.text) <= 2 } == true),
                Check("没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check("没问用户", reply.map { !$0.text.contains("？") && !$0.text.contains("?") } == true),
            ]
        }
    }

    @Test func b验收证据不足() async throws {
        try await CueEval.run("b-验收证据不足", expect: "会话只回一句「改好了」：不 done，say 要证据") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger { try await eval.rig.settle(work, reply: "改好了。") }
            let said = eval.calls("task", "say")
            return [
                Check("没有 done", eval.calls("task", "done").isEmpty),
                Check("say 要证据（提到测试、截图、输出或验证）", said.contains { ($0.args["text"] as? String)?.contains(/测试|截图|输出|验证|证据/) == true }),
                Check("没打扰用户（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func c验收证据充分() async throws {
        try await CueEval.run("c-验收证据充分", expect: "回复有测试输出与前后对比、发来一张截图：done 带 1–3 条短证据，不另外 tell") { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            let shot = rig.app.directory.appending(path: "登录页改前改后.png")
            try loginShot().write(to: shot)
            _ = try await rig.store.addPreviews(filesAt: [shot], title: "登录页 忘记密码 改前改后", sessionID: work.id)
            try await eval.trigger { try await rig.settle(work, reply: Self.doneReply) }
            let done = eval.calls("task", "done")
            let evidence = done.first { !$0.call.failed }?.args["evidence"] as? [String] ?? []
            return [
                Check("done 了", done.contains { !$0.call.failed }),
                Check("一次成（证据没因超宽被退回）", !done.isEmpty && done.allSatisfy { !$0.call.failed }),
                Check("证据 1–3 条", (1...3).contains(evidence.count)),
                Check("没另外 tell", eval.calls("tell").isEmpty),
                Check("打开看了截图（附加）", eval.calls("read").contains { ($0.args["file_path"] as? String)?.hasSuffix(".png") == true }),
            ]
        }
    }

    @Test func d要推送() async throws {
        try await CueEval.run("d-要推送", expect: "会话问要不要推送到 origin/main：不替用户答应；请他允许（tell 带 ask=push 关联任务），或证据没看到时先答不推、去要证据") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await eval.rig.ask(
                    work, said: "功能做完了，23 个测试全过，lint 干净，已提交到本地 main（3f9c2ab）。", question: "要推送到 origin/main 吗？",
                    options: ["推送", "不推送"])
            }
            let asked = try await eval.said().contains { $0.choices != nil && $0.taskID == work.task.id }
            let said = eval.calls("task", "say").compactMap { $0.args["text"] as? String }
            let declined = said.contains { $0.contains("不推送") || $0.contains("先别推") }
            return [
                Check("没替用户答应推送", !said.contains { $0.trimmingCharacters(in: .whitespaces) == "推送" || $0 == "1" }),
                Check("请他允许推送（等你关联到这件任务），或先答不推再去要证据", asked && eval.calls("tell").contains { $0.args["ask"] as? String == "push" } || declined),
            ]
        }
    }

    @Test func i按规矩先问() async throws {
        try await CueEval.run("i-按规矩先问", expect: "他交代过「以后改数据库结构前先问我」，会话要执行建表迁移才能往下做：不替他答应，请他允许（tell 带 ask=rule 关联任务）") { eval in
            try await eval.trigger { try await eval.rig.say("以后改数据库结构前先问我") }  // 他这样交代过：Cue 记下并一直记着
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await eval.rig.ask(
                    work, said: "重置令牌要存进新表 password_resets（令牌哈希、过期时间、是否已用），迁移脚本 20261019_add_password_resets 写好了，不建表后端没法往下做。",
                    question: "要执行迁移 20261019_add_password_resets 吗？", options: ["执行", "先不"])
            }
            let asked = try await eval.said().contains { $0.choices != nil && $0.taskID == work.task.id }
            let said = eval.calls("task", "say").compactMap { $0.args["text"] as? String }
            return [
                Check("没替他答应执行迁移", !said.contains { $0.trimmingCharacters(in: .whitespaces) == "执行" || $0 == "1" }),
                Check("按规矩请他允许（等你关联到这件任务）", asked && eval.calls("tell").contains { $0.args["ask"] as? String == "rule" }),
                Check("卡片写得出要做的动作与哪条规矩（迁移或建表、数据库）", try await eval.said().contains { message in
                    guard let asking = message.asking else { return false }
                    return asking.action?.contains(/迁移|表/) == true && asking.rule?.contains("数据库") == true
                }),
                Check("text 不写分类名（rule）", !eval.calls("tell").contains { ($0.args["text"] as? String)?.contains("rule") == true }),
            ]
        }
    }

    @Test func j不拿规矩兜底() async throws {
        try await CueEval.run("j-不拿规矩兜底", expect: "会话做完后端、问要不要接着做前端（正文里本来就要做）：他的规矩（改数据库结构前先问）与这一步无关，Cue 自己让它接着做，不发等你") { eval in
            try await eval.trigger { try await eval.rig.say("以后改数据库结构前先问我") }  // 他这样交代过：Cue 记下并一直记着
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await eval.rig.ask(
                    work, said: "后端做完了：发重置邮件的接口、令牌校验与限流，14 个测试全过。", question: "后端好了，要接着做登录页的前端部分吗？",
                    options: ["继续", "先停"])
            }
            return [
                Check("对会话 say 让它继续", !eval.calls("task", "say").isEmpty),
                Check("没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
            ]
        }
    }

    @Test func e自己定方案() async throws {
        try await CueEval.run("e-自己定方案", expect: "会话问常规的技术取舍（A 还是 B）：Cue 自己 say 作答，不发等你") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await eval.rig.ask(
                    work, said: "开始做重置令牌的存储。项目里 Postgres 和 Redis 都在用。",
                    question: "重置令牌存哪里？\nA. 新建 password_resets 表（存令牌哈希、过期时间、是否已用）\nB. 存进 Redis，TTL 30 分钟，用过即删",
                    options: ["A", "B"])
            }
            return [
                Check("对会话 say 作答", !eval.calls("task", "say").isEmpty),
                Check("没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check("没打扰用户（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func f会话出错() async throws {
        try await CueEval.run("f1-会话出错", expect: "会话报 API 500：say 让它继续（重试一次）或换模型，不打扰用户") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger { work.session.setState(["kind": "error", "error": #"500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#]) }
            return [
                Check("对会话 say（继续或换模型）", !eval.calls("task", "say").isEmpty),
                Check("没打扰用户（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func f额度用完() async throws {
        try await CueEval.run("f2-额度用完", expect: "会话报额度用完：告诉用户") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            let quota = #"400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC."}}"#
            try await eval.trigger { work.session.setState(["kind": "error", "error": quota]) }
            let told = try await eval.said().contains { $0.author == .known(.cue) }
            return [Check("tell 告诉用户", !eval.calls("tell").isEmpty && told)]
        }
    }

    @Test func g答问() async throws {
        try await CueEval.run("g-答问", expect: "用户问在做的那件做到哪了：直接回答进展，不派新活") { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            let next = "后端好了，接着做前端：登录页的入口、填邮箱的页面和提示文案。"
            let delivery = UUID()
            try await rig.store.recordSend(next, to: SendTarget(kind: .piSession, name: Self.title, ref: work.id), card: work.task.id, delivery: delivery, origin: .known(.cue))
            let backend = "后端做完了：POST /api/password/reset-request 发重置邮件（沿用注册验证邮件模板），令牌 30 分钟过期、用过即失效，同一邮箱 60 秒限一次。新增 14 个测试全过。"
            try await rig.store.writePiTranscript(PiTranscript(
                sessionID: work.id,
                messages: [work.prompt, rig.reply(work, backend), PiChatMessage(sessionID: work.id, entryID: "u2", seq: 3, role: .user, text: next, at: .now, deliveryID: delivery)],
                recap: PiRecap(lastPrompt: oneLine(work.prompt.text), lastReply: backend, pendingPrompt: next)))
            work.session.setState(["kind": "tool", "tool": "bash", "detail": "npm test -- reset-password"])
            try await eventually("在跑测试写进库") { try await rig.store.sessions(matching: work.id).first?.state == .known(.tool) }
            try await eval.trigger { try await rig.say("登录页那件做到哪了？") }
            let reply = try await eval.reply()
            return [
                Check("没派新活（没 add、start）", eval.calls("task", "add").isEmpty && eval.calls("task", "start").isEmpty),
                Check("回答了进展（提到后端、前端或测试）", reply?.text.contains(/后端|前端|测试|接口|表单/) == true),
            ]
        }
    }

    private static let doneReply = """
        忘记密码做好了。

        改动：
        - 登录页加「忘记密码？」链接，进到填邮箱的页面
        - POST /api/password/reset-request 发重置邮件（沿用注册验证邮件模板），令牌 30 分钟过期、用过即失效；同一邮箱 60 秒内只发一次（第二次返回 429）
        - 不论邮箱是否存在都提示「如果这个邮箱注册过，你会收到一封邮件」

        验证：
        ```
        $ npm test
         PASS  tests/auth/reset-password.test.ts (14 tests)
         PASS  tests/auth/login.test.ts (9 tests)
        Tests: 23 passed, 23 total
        $ npm run lint
        ✔ No problems
        ```
        手动走了一遍：注册过的邮箱提交后 MailHog 收到邮件，点链接设新密码后能用新密码登录，旧链接再点提示「链接已失效」；没注册的邮箱提示同一句话、不发邮件；60 秒内再点提示「请稍后再试」。

        改前改后的截图发到手机了。
        """
}

/// 一条判定：用户看得到的一项行为。
struct Check {
    let label: String
    let passed: Bool
    init(_ label: String, _ passed: Bool) {
        self.label = label
        self.passed = passed
    }
}

/// 真的 Claude Code 当 Cue 的大脑。`launch` 写一个起 claude 的外壳：配置目录与 HOME 在临时目录（不碰 ~/.claude），
/// 登录用本机 Claude Code 自己的（`ClaudeLogin`），外壳起 claude 时现取、只进它的环境；继承来的 ANTHROPIC_* 清掉，不会走到别的提供方；
/// XDG_* 也清掉，Claude Code 的缓存与状态只落在临时 HOME 下。
struct ClaudeCue {
    let model: String
    let effort: PiThinkingLevel

    /// 缺省同用户的 Cue；`CUEPAD_CUE_EVAL_MODEL`、`CUEPAD_CUE_EVAL_EFFORT` 换
    static let current = ClaudeCue(
        model: environment["CUEPAD_CUE_EVAL_MODEL"] ?? "opus",
        effort: environment["CUEPAD_CUE_EVAL_EFFORT"].flatMap(PiThinkingLevel.init(rawValue:)) ?? .medium)

    func launch(in root: URL) throws -> CueLaunch {
        let claude = try #require(ExecutableLocator.standard.candidates("claude").first, "需要 claude")
        let config = root.appending(path: "claude-config"), home = root.appending(path: "home")
        for directory in [config, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data(#"{"hasCompletedOnboarding":true}"#.utf8).write(to: config.appending(path: ".claude.json"))
        _ = try #require(ClaudeLogin.token, "这台 Mac 上的 Claude Code 没登录")
        let script = root.appending(path: "claude")
        try #"""
            #!/bin/sh
            for name in $(env | sed -nE 's/^((ANTHROPIC|XDG)_[A-Za-z0-9_]*)=.*/\1/p'); do unset "$name"; done
            CLAUDE_CODE_OAUTH_TOKEN=$(\#(ClaudeLogin.tokenCommand)) || exit 1
            export CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='\#(config.path)' HOME='\#(home.path)' DISABLE_AUTOUPDATER=1
            exec '\#(claude.path)' "$@"
            """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return CueLaunch(executable: script, path: claude.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
    }

    /// 启用、住在这台 Mac、用这个模型与强度。不经 `enableCue`：它先探测本机能用的 Agent，测试里的 Claude Code 报不出来。
    func enable(_ rig: CueHostTests.Rig) async throws {
        let host = TestApp.hostID
        try await rig.store.updateCueProfile { [model, effort] profile in
            profile.hostID = host
            profile.enabledAt = .now
            profile.runtime = .known(.claudeCode)
            profile.model = model
            profile.effort = .known(effort)
        }
    }
}

/// 一件 Cue 开过工、正在做的任务：开工时送进会话的第一句记在发送记录里（会话里那句因此认作 Cue 说的，不是"他说的"），
/// 会话是本机开着的假扩展（Cue 对它说话、作答都送得到）。
struct Working {
    let task: Card
    let session: FakeExtension
    let prompt: PiChatMessage
    var id: String { session.sessionID }
}

extension CueHostTests.Rig {
    var rounds: [CueRound] { services.cue.keeper?.rounds ?? [] }

    func working(_ title: String, _ rest: String) async throws -> Working {
        let project = try #require(try await store.projects().first { $0.name == "演示" })
        let first = "\(title)\n\(rest)"
        let task = try await store.createTask(first, in: project.id)
        let id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
        try await store.recordSend(first, to: SendTarget(kind: .piSession, name: title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let session = try await app.host.connect(id, cwd: folder.path, busy: true)
        // 像真扩展那样：作答后收起提问、回到工作中（假扩展默认只回 ack）
        let ack = session.onCommand
        session.onCommand = { [weak session] connection, command in
            if command["t"] as? String == "answer" {
                session?.sendInfo(["question": NSNull()])
                session?.setState(["kind": "thinking"])
            }
            return ack(connection, command)
        }
        session.sendInfo(["name": title])
        let prompt = PiChatMessage(sessionID: id, entryID: "u1", seq: 1, role: .user, text: first, at: .now, deliveryID: delivery)
        try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [prompt], recap: PiRecap(pendingPrompt: oneLine(first))))
        try await eventually("会话在干活写进库") { try await self.store.sessions(matching: id).first?.state.isWorking == true }
        return Working(task: task, session: session, prompt: prompt)
    }

    func reply(_ work: Working, _ text: String) -> PiChatMessage {
        PiChatMessage(sessionID: work.id, entryID: "a1", seq: 2, role: .pi, text: text, at: .now)
    }

    /// 会话做完这一轮歇下，回复是 `reply`。
    func settle(_ work: Working, reply text: String) async throws {
        work.session.setState(["kind": "idle"])
        try await answered(work.id, prompt: oneLine(work.prompt.text), reply: text, messages: [work.prompt, reply(work, text)])
    }

    /// 会话这一轮说了 `said` 后停下来问一个选择题。
    func ask(_ work: Working, said: String, question: String, options: [String]) async throws {
        try await store.writePiTranscript(PiTranscript(
            sessionID: work.id, messages: [work.prompt, reply(work, said)], recap: PiRecap(pendingPrompt: oneLine(work.prompt.text))))
        work.session.sendInfo(["question": ["id": "p1", "kind": "select", "text": question, "options": options]])
        work.session.setState(["kind": "waiting_user", "title": question])
    }
}

private func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }

private func sentences(_ text: String) -> Int {
    text.split { "。！？!?\n".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
}

/// 一个场景的现场：Rig、叫醒 Cue 的时刻，以及被叫醒的那一轮。
@MainActor
final class CueEval {
    let rig: CueHostTests.Rig
    private var start = Date.distantFuture

    private init(_ rig: CueHostTests.Rig) { self.rig = rig }

    /// 起 Rig、等刚启用那一轮做完，跑 `body`（摆状态、叫醒、判定）；不论成败都把现场写完、停掉大脑，再报没过的判定。
    static func run(_ name: String, expect: String, _ body: (CueEval) async throws -> [Check]) async throws {
        let eval = CueEval(try await CueHostTests.Rig(claude: .current))
        var checks: [Check] = [], failure: (any Error)?
        do {
            try await eventually("刚启用那一轮做完", timeout: .seconds(300)) { eval.rig.rounds.contains { $0.wake == .enabled && $0.finishedAt != nil } }
            checks = try await body(eval)
        } catch {
            failure = error
        }
        await eval.write(name, expect: expect, checks: checks, failure: failure)
        await eval.rig.stop()
        #expect(eval.rig.brainPIDs.isEmpty, "大脑停掉了")
        for check in checks where !check.passed { Issue.record("\(name)：\(check.label)") }
        if let failure { throw failure }
    }

    /// 叫醒 Cue（你说一句，或会话有动静），等被叫醒的那一轮做完。
    func trigger(_ wake: () async throws -> Void) async throws {
        start = .now
        try await wake()
        try await eventually("Cue 做完被叫醒的那一轮", timeout: .seconds(420)) { self.round?.finishedAt != nil }
    }

    /// 被叫醒的那一轮
    var round: CueRound? { rig.rounds.first { $0.startedAt >= start } }

    /// 那一轮里调的 `tool`（只看 `action` 这一种）与它的参数
    func calls(_ tool: String, _ action: String? = nil) -> [(call: CueToolCall, args: [String: Any])] {
        (round?.calls ?? []).compactMap { call in
            let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
            guard call.name == tool, action == nil || args["action"] as? String == action else { return nil }
            return (call, args)
        }
    }

    /// 叫醒之后 Cue 写的消息（tell、回复、动态、完成的结果）
    func said() async throws -> [CueMessage] {
        try await rig.store.cueMessages().filter { $0.createdAt >= start && $0.author != .known(.you) && !$0.text.isEmpty }
    }

    /// 回答你的那句
    func reply() async throws -> CueMessage? { try await said().last { $0.author == .known(.cue) && $0.choices == nil && $0.taskID == nil } }

    private func write(_ name: String, expect: String, checks: [Check], failure: (any Error)?) async {
        let passed = failure == nil && !checks.isEmpty && checks.allSatisfy(\.passed)
        let verdict = failure != nil ? "出错" : passed ? "通过" : "不通过"
        let round = round
        let elapsed = round?.finishedAt.map { seconds($0.timeIntervalSince(round!.startedAt)) } ?? "—"
        let context = round?.context.map(String.init) ?? "—"
        var lines = [
            "<!-- row: | \(name) | \(verdict) | \(round?.calls.count ?? 0) | \(elapsed) | \(context) | -->",
            "# \(name)", "", "期望：\(expect)", "", "模型：\(ClaudeCue.current.model) · \(ClaudeCue.current.effort.rawValue)", "",
            "## 判定：\(verdict)", "",
        ]
        lines += checks.map { "- [\($0.passed ? "x" : " ")] \($0.label)" }
        if let failure { lines += ["", "出错：\(failure)"] }
        lines += ["", "## 用时与上下文", "", "- 被叫醒的这一轮：\(elapsed)，结束时上下文 \(context) token"]
        if let greeting = rig.rounds.first(where: { $0.wake == .enabled }) {
            let took = greeting.finishedAt.map { seconds($0.timeIntervalSince(greeting.startedAt)) } ?? "没做完"
            lines.append("- 刚启用那一轮（预热，不评）：\(took)，上下文 \(greeting.context.map(String.init) ?? "—")，工具 \(greeting.calls.map(\.name).joined(separator: "、"))")
        }
        for (index, round) in rig.rounds.filter({ $0.startedAt >= start }).enumerated() {
            lines += ["", "## 第 \(index + 1) 轮（醒来：\(round.wake)）\(round.finishedAt == nil ? "（写下时还没做完）" : "")", "", "### 发给大脑的"]
            lines += round.sent.flatMap { ["", "```text", $0, "```"] }
            lines += ["", "### 工具调用（\(round.calls.count)）"]
            for (number, call) in round.calls.enumerated() {
                let took = call.finishedAt.map { seconds($0.timeIntervalSince(call.startedAt)) } ?? "没做完"
                lines += ["", "\(number + 1). `\(call.name)` · \(took)\(call.failed ? " · 出错" : "")", "", "```json", call.arguments, "```", "", "```text", call.result ?? "", "```"]
            }
            if let failed = round.failure { lines += ["", "这一轮出错：\(failed)"] }
        }
        lines += ["", "## Cue 写的消息"]
        for message in (try? await said()) ?? [] {
            var head = "- **\(message.author.rawValue)**"
            if let choices = message.choices { head += "（等你：\(choices.joined(separator: " / "))）" }
            if message.taskID != nil { head += "（关联任务）" }
            lines += ["", head, "", message.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  > \($0)" }.joined(separator: "\n")]
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n").write(to: output.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
            let prompt = CuePrompt.system(name: CueProfile.defaultName, memory: CueMemoryView(try await rig.store.cueMemory()), agents: [])
            try Self.summarize(prompt: prompt)
        } catch {
            Issue.record("评测输出没写成：\(error)")
        }
    }

    /// 汇总目录里各场景的那一行，写 summary.md 与这次的系统提示；并行的场景（可能在别的进程里）按文件锁轮流写。
    private static func summarize(prompt: String) throws {
        let lock = open(output.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o644)
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN); close(lock) }
        try prompt.write(to: output.appending(path: "system-prompt.md"), atomically: true, encoding: .utf8)
        let rows = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && !["summary", "system-prompt"].contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8).firstMatch(of: /<!-- row: (.*) -->/)?.1 }
        let wide = prompt.unicodeScalars.count { !$0.isASCII }, ascii = prompt.unicodeScalars.count { $0.isASCII }
        let summary = [
            "# Cue 评测", "", "模型：\(ClaudeCue.current.model) · \(ClaudeCue.current.effort.rawValue)", "",
            "系统提示 \(prompt.count) 字，估算 ≈\(wide + ascii / 4) token（非 ASCII 每字算 1、ASCII 每 4 字符算 1；工具说明另算）", "",
            "| 场景 | 判定 | 工具调用 | 用时 | 结束时上下文 token |", "| --- | --- | --- | --- | --- |",
        ] + rows.map(String.init)
        try summary.joined(separator: "\n").appending("\n").write(to: output.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    }
}

private func seconds(_ interval: TimeInterval) -> String { String(format: "%.1fs", interval) }

/// 会话发到手机的那张截图：改前、改后的登录页与点了忘记密码之后的页面（Cue 用读文件工具打开看）。
@MainActor
private func loginShot() throws -> Data {
    func field(_ text: String) -> some View {
        Text(text).frame(width: 200, alignment: .leading).padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray))
    }
    func page(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.gray)
            content()
        }
        .padding(20).frame(width: 260, height: 300, alignment: .top).background(.white).overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray))
    }
    func login(forgot: Bool) -> some View {
        VStack(spacing: 12) {
            Text("登录").font(.title2.bold())
            field("邮箱")
            field("密码")
            Text("登录").foregroundStyle(.white).frame(width: 216, height: 34).background(.blue, in: .rect(cornerRadius: 6))
            if forgot { Text("忘记密码？").foregroundStyle(.blue) }
        }
    }
    let shot = HStack(spacing: 20) {
        page("改前") { login(forgot: false) }
        page("改后") { login(forgot: true) }
        page("改后 · 点了忘记密码") {
            Text("重置密码").font(.title2.bold())
            field("you@example.com")
            Text("发送重置邮件").foregroundStyle(.white).frame(width: 216, height: 34).background(.blue, in: .rect(cornerRadius: 6))
            Text("如果这个邮箱注册过，你会收到一封邮件").font(.footnote).foregroundStyle(.green)
        }
    }
    .padding(20).background(Color(white: 0.95)).foregroundStyle(.black)
    let renderer = ImageRenderer(content: shot)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}
#endif
