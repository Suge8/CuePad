#if os(macOS)
import CueStore
import Foundation

extension AgentFacts {
    /// 这台上的它（`presence`）要跑的官方命令：接入面板与设置里的"安装""升级"在后台跑它，设置那一行的悬停提示写出它。
    public func installCommand(_ presence: AgentStatus.Presence) -> String {
        upgrades(presence) ? upgradeCommand ?? installScript : installScript
    }

    /// 这台上的它要升级、不是新装（设置里的"升级"）：太旧而有自带的升级命令；别家太旧也是重跑安装命令。
    public func upgrades(_ presence: AgentStatus.Presence) -> Bool {
        if upgradeCommand != nil, case .tooOld = presence { true } else { false }
    }
}

/// 装一家之前要先有的程序（`AgentFacts.installPrerequisite`）。
public struct InstallPrerequisite: Sendable, Equatable {
    public let name: String
    /// 可执行文件名，`--version` 报出版本
    public let command: String
    public let minimum: AgentVersion
    /// 官网：没有时给人去装
    public let site: URL
}

/// 在后台装一家 Agent、登录它。官方脚本装进家目录（`~/.local/bin`、OpenCode 的 `~/.opencode/bin`，检测本来就查那里），没有终端时不问问题。
extension AgentIntegration {
    /// 跑这家的安装命令（`installCommand`），等它结束：返回退出码与输出（标准错误并在一起，失败时取末尾给人看）；起不来或超过 `installLimit` 为 nil。
    @concurrent public func runInstaller(_ kind: AgentKind, _ presence: AgentStatus.Presence) async -> (status: Int32, output: String)? {
        let shell = URL(filePath: "/bin/sh")
        let environment = await locate().environment(launching: shell, overrides: paths.environment)
        return await ChildProcess.run(
            shell, ["-c", "{ \(installCommand(kind, presence)); } 2>&1"], environment: environment, timeout: Self.installLimit)
    }

    /// 起这家的命令行登录（`AgentFacts.loginArguments`），用检测挑中的那个可执行文件；返回时进程已起，它打开浏览器、等你登录完。
    public func startLogin(_ kind: AgentKind, executable: URL) async throws -> ChildProcess {
        let environment = await locate().environment(launching: executable, overrides: paths.environment)
        // 标准输入、输出、错误都是空设备，自成进程组：调用方 `waitForExit()` 等它结束、`end()` 提前结束它
        return try await ChildProcess(executable, kind.facts.loginArguments ?? [], environment: environment, placement: .group, keepErrors: false)
    }

    /// 开终端登录 Pi 的脚本（Pi 只能在它的终端界面里 /login）：带上 CuePad 起 Pi 时的家目录、PATH（node 在里面）与 Pi 的环境
    /// （`PiPaths.launchEnvironment`），登录进 CuePad 用的同一个配置目录；在家目录里起（终端默认的目录，隔离运行时是换走的那个）。
    public func piLoginScript(executable: URL) async -> String {
        let launching = await locate().environment(launching: executable, overrides: paths.environment)
        let environment = paths.pi.launchEnvironment.merging(["HOME": launching["HOME"] ?? NSHomeDirectory(), "PATH": launching["PATH"] ?? ""]) { $1 }
        let exports = environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(AgentSkill.shellQuoted($0.value))" }
        return (["#!/bin/sh", "clear"] + exports + ["cd \"$HOME\"", "exec \(AgentSkill.shellQuoted(executable.path))"]).joined(separator: "\n") + "\n"
    }

    /// 实测（2026-10）Claude Code 下载约 260 MB，慢的网络要七八分钟
    static let installLimit = Duration.seconds(30 * 60)
}
#endif
