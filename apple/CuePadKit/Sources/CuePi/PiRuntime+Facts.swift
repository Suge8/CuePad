#if os(macOS)
import CueStore
import Foundation

extension PiRuntime {
    /// 全局规则读配置目录里 `AGENTS.override.md`、`AGENTS.md`、`CLAUDE.md` 第一份在的（1.5.0 的 resource-loader；大小写不分的盘上 `.MD` 同名）。
    /// 最低 1.4.0：官方原包验证了 agent_settled、context_edit 与命令空闲等待。抬它时同一改动里把测试钉住的 Pi（`CuePadKit/Tests/agents.json`）换成这一版跑一遍 CuePiTests。官方脚本要 Node.js（下限是脚本里写的），没有时只报一句英文就退出。
    nonisolated public static let facts = AgentFacts(
        command: "pi", homeVariable: "PI_CODING_AGENT_DIR", home: { $0.pi.agentDirectory }, minimumVersion: AgentVersion(1, 4, 0),
        installScript: "curl -fsSL https://pi.dev/install.sh | sh", upgradeCommand: "pi update --self",
        installPrerequisite: InstallPrerequisite(name: "Node.js", command: "node", minimum: AgentVersion(22, 19, 0), site: URL(string: "https://nodejs.org")!),
        homeMeansInstalled: false,
        sessionFiles: SessionFileFormat(ingest: PiHistory.ingest, depth: 2, naming: .idSuffix) { $0.pi.sessionsDirectory },
        channel: { integration, _ in PiExtensionFiles(extensionsDirectory: integration.paths.pi.extensionsDirectory) },
        hostingNeedsChannel: true, probe: askPi, brain: { PiBrain() }, projectFolder: ".pi",
        globalReads: ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"])

    /// RPC 模式、不存会话，只加载随包的桥扩展（不加载装好的那份与其他扩展，也就不连 CuePad）并开探测模式（扩展的 `CUEPAD_PROBE`）：
    /// 扩展把会话里上报的同一份模型配置写成一行就收尾。可选的与 Pi 的 /model 同一规则，配了范围（`enabledModels`）就是范围内的。
    /// 没有可用的模型是没登录。
    nonisolated private static func askPi(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        let arguments = [
            "--mode", "rpc", "--no-session", "--offline", "--no-extensions", "--extension", PiExtensionBundle.url.path,
            "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
        ]
        let environment = probe.locator.environment(
            launching: executable, overrides: probe.paths.pi.launchEnvironment.merging(["CUEPAD_PROBE": "1"]) { $1 })
        guard let result = await ChildProcess.run(executable, arguments, environment: environment, timeout: AgentTimeouts.probe, timing: probe.timing)
        else { throw AgentProbe.ProbeError.timedOut }
        guard let reply = result.output.split(separator: "\n").lazy.compactMap({ AgentProbe.PluginReply(line: Data($0.utf8)) }).first
        else { throw AgentProbe.ProbeError.noAnswer(status: result.status) }
        return reply.agent(.pi)
    }
}
#endif
