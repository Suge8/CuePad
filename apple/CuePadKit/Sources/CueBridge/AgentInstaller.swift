#if os(macOS)
import CueStore
import Foundation

extension AgentFacts {
    public func installCommand(_ presence: AgentStatus.Presence) -> String {
        upgrades(presence) ? upgradeCommand ?? installScript : installScript
    }

    public func upgrades(_ presence: AgentStatus.Presence) -> Bool {
        if upgradeCommand != nil, case .tooOld = presence { true } else { false }
    }
}

public struct InstallPrerequisite: Sendable, Equatable {
    public let name: String
    public let command: String
    public let minimum: AgentVersion
    public let site: URL
}

/// 官方脚本装进家目录（`~/.local/bin`、OpenCode 的 `~/.opencode/bin`，检测本来就查那里）。
extension AgentIntegration {
    /// 返回退出码与输出（标准错误并在一起，失败时取末尾给人看）；起不来或超过 `installLimit` 为 nil。
    @concurrent public func runInstaller(_ kind: AgentKind, _ presence: AgentStatus.Presence) async -> (status: Int32, output: String)? {
        let shell = URL(filePath: "/bin/sh")
        let environment = await locate().environment(launching: shell, overrides: paths.environment)
        return await ChildProcess.run(
            shell, ["-c", "{ \(installCommand(kind, presence)); } 2>&1"], environment: environment, timeout: Self.installLimit)
    }

    /// 返回时进程已起：调用方 `waitForExit()` 等它结束、`end()` 提前结束它。
    public func startLogin(_ kind: AgentKind, executable: URL) async throws -> ChildProcess {
        let environment = await locate().environment(launching: executable, overrides: paths.environment)
        return try await ChildProcess(executable, kind.facts.loginArguments ?? [], environment: environment, placement: .group, keepErrors: false)
    }

    /// Pi 只能在它的终端界面里 /login：脚本带上 CuePad 起 Pi 时的家目录、PATH（node 在里面）与 Pi 的环境
    /// （`PiPaths.launchEnvironment`），登录进 CuePad 用的同一个配置目录；在家目录里起（终端默认的目录，隔离运行时是换走的那个）。
    public func piLoginScript(executable: URL) async -> String {
        let launching = await locate().environment(launching: executable, overrides: paths.environment)
        let environment = paths.pi.launchEnvironment.merging(["HOME": launching["HOME"] ?? paths.userHome.path, "PATH": launching["PATH"] ?? ""]) { $1 }
        let exports = environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(AgentSkill.shellQuoted($0.value))" }
        return (["#!/bin/sh", "clear"] + exports + ["cd \"$HOME\"", "exec \(AgentSkill.shellQuoted(executable.path))"]).joined(separator: "\n") + "\n"
    }

    /// 实测（2026-10）Claude Code 下载约 260 MB，慢的网络要七八分钟
    static let installLimit = Duration.seconds(30 * 60)
}
#endif
