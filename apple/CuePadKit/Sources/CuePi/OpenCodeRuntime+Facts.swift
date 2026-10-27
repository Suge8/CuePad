#if os(macOS)
import CueStore
import Foundation

extension OpenCodeRuntime {
    /// 只认 v2（v1 的服务接口不同，不做兼容；Homebrew 与官方脚本装的是 v2，npm 上 v2 是 `@opencode/cli`，旧包 `opencode-ai` 仍是 1.x），
    /// 太旧也是重跑 v2 的安装命令替换它。会话在它的数据库里，由接入直连它的后台服务，不用装上报通道。
    /// 旧技能目录还认单数的 `skill`；全局说明不链：没有自己那份时它读 Claude Code 的。
    nonisolated public static let facts = AgentFacts(
        command: "opencode", homeVariable: "OPENCODE_CONFIG_DIR",
        home: home, minimumVersion: AgentVersion(2, 0, 0), installScript: "curl -fsSL https://opencode.ai/v2/install | bash", probe: ask,
        skillFolders: ["skills", "skill"], projectFolder: ".opencode", linksGlobalInstructions: false)

    nonisolated private static func home(_ paths: AgentPaths) -> URL {
        paths.directory(facts.homeVariable) ?? paths.xdg("XDG_CONFIG_HOME", ".config").appending(path: "opencode", directoryHint: .isDirectory)
    }

    /// 还没有模型清单：找得到命令行程序就算能用。
    nonisolated private static func ask(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        MacAgent(kind: .opencode, model: nil, models: [])
    }

    /// 关掉开关：CuePad 拉起的服务一并停掉（本来就在跑的不动）。
    public func integrationRemoved() async { await stopStartedService()() }
}
#endif
