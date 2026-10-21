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

/// 当 Cue 的大脑的真 Agent：缺省 Claude Code（opus · medium，同用户的 Cue）；`CUEPAD_CUE_EVAL_RUNTIME=pi` 换成 Pi（anthropic/claude-sonnet-5-5 · medium）；
/// `CUEPAD_CUE_EVAL_MODEL`、`CUEPAD_CUE_EVAL_EFFORT` 换模型与强度。`launch` 写一个起它的外壳，配置与 HOME 在临时目录，
/// 继承来的 ANTHROPIC_*、XDG_* 清掉，登录在外壳起进程时现取、只进它的环境：
/// - Claude Code 用它自己存在钥匙串里的那条（`ClaudeLogin`），配置目录 `CLAUDE_CONFIG_DIR` 在临时目录（不碰 ~/.claude）；
/// - Pi 用 `ANTHROPIC_OAUTH_TOKEN`，从 ~/.pi/agent/auth.json 的 anthropic.access 只读地取。不拷 auth.json、不替它刷新：
///   刷新会用掉一次性的刷新令牌，把用户挤下线；令牌过期就起不来，等他自己的 Pi 续上。`PI_CODING_AGENT_DIR` 在临时目录。
/// 开销从评测这边取：外壳把大脑的 stdout 另存一份到 `usage` 目录（每个大脑进程一个文件，`BrainUsage` 读），
/// 用 bash 的进程替换接 tee 再 exec，大脑仍是外壳这个进程，退出码与流都不变。
struct EvalBrain {
    let runtime: AgentKind
    let model: String
    let effort: PiThinkingLevel

    static let current: EvalBrain = {
        let pi = evalEnvironment["CUEPAD_CUE_EVAL_RUNTIME"] == "pi"
        return EvalBrain(
            runtime: pi ? .pi : .claudeCode, model: evalEnvironment["CUEPAD_CUE_EVAL_MODEL"] ?? (pi ? "anthropic/claude-sonnet-5-5" : "opus"),
            effort: evalEnvironment["CUEPAD_CUE_EVAL_EFFORT"].flatMap(PiThinkingLevel.init(rawValue:)) ?? .medium)
    }()

    /// .md 与 summary.md 开头那一行：大脑、模型与强度、上下文做法
    var label: String { "\(runtime.name) · \(model) · \(effort.rawValue) · 精简混合（到换新线或缓存过期开新会话，用记忆视图与最近对话接上）" }

    /// Pi 的登录：用户的 Pi 存的那一份，只读
    private static let piAuth = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent/auth.json")

    /// 评测给 Pi 多加载的只读扩展：每次请求模型前记下 user-agent 与系统提示首块是不是计费标识（在大脑自己的扩展之后加载，看到的是它们改过的），
    /// 证明请求走的是带 Claude 订阅计费标识的那条路；什么都不改。
    private static let billingLog = """
        import { appendFileSync } from "node:fs";
        const log = process.env.CUEPAD_EVAL_BILLING_LOG;
        export default function (pi: any) {
          pi.on("before_provider_headers", (event: any) => {
            if (log) appendFileSync(log, JSON.stringify({ kind: "headers", ua: event.headers?.["user-agent"] ?? null }) + "\\n");
          });
          pi.on("before_provider_request", (event: any) => {
            const first = Array.isArray(event.payload?.system) ? event.payload.system[0]?.text : undefined;
            if (log) appendFileSync(log, JSON.stringify({ kind: "request", billing: typeof first === "string" && first.startsWith("x-anthropic-billing-header:") }) + "\\n");
          });
        }
        """

    func launch(in root: URL) throws -> CuePad.CueLaunch {
        let home = root.appending(path: "home"), usage = BrainUsage.directory(in: root)
        for directory in [home, usage] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let script = root.appending(path: "brain")
        let executable: URL, login: String
        var extra = ""
        switch runtime {
        case .pi:
            executable = realPi
            let agent = root.appending(path: "pi-agent")
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            let auth = try #require(
                (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.piAuth))) as? [String: Any], "这台 Mac 上的 Pi 没登录")["anthropic"] as? [String: Any]
            let expires = try #require(auth?["expires"] as? Double, "Pi 没有 Anthropic 的登录")
            try #require(Date(timeIntervalSince1970: expires / 1000) > .now, "Pi 的 Anthropic 令牌已过期：等用户自己的 Pi 续上，评测不替它刷新")
            let billing = root.appending(path: "billing-log.ts")
            try Self.billingLog.write(to: billing, atomically: true, encoding: .utf8)
            login = """
                ANTHROPIC_OAUTH_TOKEN=$(/usr/bin/plutil -extract anthropic.access raw -o - '\(Self.piAuth.path)') || exit 1
                export ANTHROPIC_OAUTH_TOKEN PI_CODING_AGENT_DIR='\(agent.path)' CUEPAD_EVAL_BILLING_LOG='\(BrainUsage.billingLog(in: root).path)'
                """
            extra = " -e '\(billing.path)'"
        default:
            executable = try #require(ExecutableLocator.standard.candidates("claude").first, "需要 claude")
            let config = root.appending(path: "claude-config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try Data(#"{"hasCompletedOnboarding":true}"#.utf8).write(to: config.appending(path: ".claude.json"))
            _ = try #require(ClaudeLogin.token, "这台 Mac 上的 Claude Code 没登录")
            login = """
                CLAUDE_CODE_OAUTH_TOKEN=$(\(ClaudeLogin.tokenCommand)) || exit 1
                export CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='\(config.path)' DISABLE_AUTOUPDATER=1
                """
        }
        try #"""
            #!/bin/bash
            for name in $(env | sed -nE 's/^((ANTHROPIC|XDG)_[A-Za-z0-9_]*)=.*/\1/p'); do unset "$name"; done
            \#(login)
            export HOME='\#(home.path)'
            exec > >(exec tee '\#(usage.path)'/"$(date +%s)-$$.jsonl")
            exec '\#(executable.path)' "$@"\#(extra)
            """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return CuePad.CueLaunch(executable: script, path: executable.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
    }

    /// 启用、运行在这台 Mac、用这个大脑、模型与强度。不经 `enableCue`：它先探测本机能用的 Agent，测试里的报不出来。
    func enable(_ rig: CueHostTests.Rig) async throws {
        let host = TestApp.hostID
        try await rig.store.updateCueProfile { [runtime, model, effort] profile in
            profile.hostID = host
            profile.enabledAt = .now
            profile.runtime = .known(runtime)
            profile.model = model
            profile.effort = .known(effort)
        }
    }
}
#endif
