#if os(macOS)
import CueStore
import Foundation

extension AgentKind {
    /// 官方安装命令（取自各家官网的安装页，唯一一份）：接入面板的"安装"在后台跑它，设置里的安装方法给你复制它。
    /// Pi 太旧时是它自带的升级命令；OpenCode 是 v2 的安装命令（v1 的服务接口不同）。
    public func installCommand(upgrading: Bool) -> String {
        switch self {
        case .pi: upgrading ? "pi update --self" : "curl -fsSL https://pi.dev/install.sh | sh"
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        case .opencode: "curl -fsSL https://opencode.ai/v2/install | bash"
        }
    }

    /// 命令行登录的参数：打开浏览器，在网页上登录完它自己退出（不要终端）。Pi 没有，只能在它的终端界面里输入 /login。
    public var loginArguments: [String]? {
        switch self {
        case .claudeCode: ["auth", "login"]
        case .codex: ["login"]
        case .pi, .opencode: nil
        }
    }
}

/// 在后台装一家 Agent、登录它。三家的官方脚本都装进 `~/.local/bin`（检测本来就查那里），没有终端时不问问题；
/// Pi 的脚本要 Node.js 22 以上，没有时不能在后台装，报出脚本自己的那句。
extension AgentIntegration {
    /// 跑这家的安装命令（`installCommand`），等它结束：返回退出码与输出（标准错误并在一起，失败时取末尾给人看）；起不来或超过 `installLimit` 为 nil。
    @concurrent public func runInstaller(_ kind: AgentKind, upgrading: Bool) async -> (status: Int32, output: String)? {
        let shell = URL(filePath: "/bin/sh")
        let environment = await locate().environment(launching: shell, overrides: paths.environment)
        return await ChildProcess.run(
            shell, ["-c", "{ \(installCommand(kind, upgrading)); } 2>&1"], environment: environment, timeout: Self.installLimit)
    }

    /// 起这家的命令行登录（`AgentKind.loginArguments`），用检测挑中的那个可执行文件；返回时进程已起，它打开浏览器、等你登录完。
    public func startLogin(_ kind: AgentKind, executable: URL) async throws -> ChildProcess {
        let environment = await locate().environment(launching: executable, overrides: paths.environment)
        return try ChildProcess.launch(executable, kind.loginArguments ?? [], environment: environment)
    }

    /// 开终端登录 Pi 的脚本（Pi 只能在它的终端界面里 /login）：带上 CuePad 起 Pi 时的环境（`PiPaths.launchEnvironment`），登录进同一个配置目录。
    public func piLoginScript(executable: URL) -> String {
        let exports = paths.pi.launchEnvironment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(AgentSkill.shellQuoted($0.value))" }
        return (["#!/bin/sh", "clear"] + exports + ["exec \(AgentSkill.shellQuoted(executable.path))"]).joined(separator: "\n") + "\n"
    }

    /// 实测（2026-10）Claude Code 下载约 260 MB，慢的网络要七八分钟
    static let installLimit = Duration.seconds(30 * 60)
}
#endif
