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

/// 真的 Claude Code 当 Cue 的大脑。`launch` 写一个起 claude 的外壳：配置目录与 HOME 在临时目录（不碰 ~/.claude），
/// 登录用本机 Claude Code 自己的（`ClaudeLogin`），外壳起 claude 时现取、只进它的环境；继承来的 ANTHROPIC_* 清掉，不会走到别的提供方；
/// XDG_* 也清掉，Claude Code 的缓存与状态只落在临时 HOME 下。
struct ClaudeCue {
    let model: String
    let effort: PiThinkingLevel

    /// 缺省同用户的 Cue；`CUEPAD_CUE_EVAL_MODEL`、`CUEPAD_CUE_EVAL_EFFORT` 换
    static let current = ClaudeCue(
        model: ProcessInfo.processInfo.environment["CUEPAD_CUE_EVAL_MODEL"] ?? "opus",
        effort: ProcessInfo.processInfo.environment["CUEPAD_CUE_EVAL_EFFORT"].flatMap(PiThinkingLevel.init(rawValue:)) ?? .medium)

    func launch(in root: URL) throws -> CuePad.CueLaunch {
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
        return CuePad.CueLaunch(executable: script, path: claude.deletingLastPathComponent().path + ":/usr/bin:/bin", agents: [])
    }

    /// 启用、运行在这台 Mac、用这个模型与强度。不经 `enableCue`：它先探测本机能用的 Agent，测试里的 Claude Code 报不出来。
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
#endif
