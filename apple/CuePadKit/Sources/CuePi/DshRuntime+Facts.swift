#if os(macOS)
import CueStore
import Foundation

extension DshRuntime {
    /// 最低 0.2.1-rc.2（npm 上 `latest` 标的那版，往前没有实测）：要有 `--profile acp` 的多会话、模型与强度选项、插件的 `agent.steer`。
    /// 只在 npm 上发（`@deepseek-ai/dsh`，全是预发布版），要 Node.js（下限取它依赖里最高的 `engines`）；太旧也是重跑安装命令。
    /// 没有命令行登录：`dsh web` 打开它的网页，在设置里填 DeepSeek 的 API key 或登录 DeepSeek 账号（都存进 `$DSH_HOME/.credentials.yaml`），
    /// 环境里的 `DEEPSEEK_API_KEY` 它也认。只有桌面版时配置目录在、命令行程序不在：算装着（技能与规则照写），开不出会话。
    /// 没有上报通道：会话只有 CuePad 托管的，插件随每次启动经 `--patch` 叠上（`DshLaunch`），不装进它的目录。
    /// 技能读 `<DSH_HOME>/skills` 与 `~/.agents/skills` 的一层（`<名>/SKILL.md`，分类目录里的看不到）；全局规则读 `<DSH_HOME>/AGENTS.md`
    /// 再读 `~/.agents/AGENTS.md`（内容相同只算一份），所以照多数家链过去。
    nonisolated public static let facts = AgentFacts(
        command: "dsh", homeVariable: "DSH_HOME", home: home, minimumVersion: AgentVersion(0, 2, 1, prerelease: "rc.2"),
        installScript: "npm install -g @deepseek-ai/dsh",
        installPrerequisite: InstallPrerequisite(name: "Node.js", command: "node", minimum: AgentVersion(22, 19, 0), site: URL(string: "https://nodejs.org")!),
        loginArguments: ["web"],
        sessionFiles: SessionFileFormat(ingest: DshHistory.ingest, depth: 3, naming: .inDirectory(file: DshHistory.fileName)) {
            home($0).appending(path: sessions, directoryHint: .isDirectory)
        },
        releasesIdleHosted: true, probe: askDsh, brain: { DshBrain() }, projectFolder: ".dsh")

    nonisolated static func home(_ paths: AgentPaths) -> URL { paths.directory(facts.homeVariable) ?? paths.user(".dsh") }

    /// CuePad 托管的会话的存储根（在 DSH_HOME 下，明文；理由见 `DshRuntime` 头注释）
    nonisolated static let sessions = "cuepad/sessions"

    /// 起一个不答 ACP 的进程，插件的探测模式（`CUEPAD_PROBE`）把模型清单写成一行就退出：与会话的模型菜单同一份（各提供方的清单），
    /// 缺省是新会话用的模型。一个模型都没有是没登录（没有 key、也没登录账号）。标准输入要一直开着：一关 dsh 就收场，清单还没问完。
    nonisolated private static func askDsh(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        let launch = try DshLaunch.hosted(probe.paths)
        let environment = probe.locator.environment(launching: executable, overrides: launch.environment.merging(["CUEPAD_PROBE": "1"]) { $1 })
        let process = try await ChildProcess(
            executable, launch.arguments, directory: FileManager.default.temporaryDirectory, environment: environment, placement: .group,
            input: .lifeline, output: .lines)
        struct Line: Decodable {
            let cuepadProbe: Models
            struct Models: Decodable {
                let model: PiModelOption?
                let models: [PiModelOption]
            }
        }
        let decoder = JSONDecoder()
        let reply = await process.output.compactMap { try? decoder.decode(Line.self, from: $0).cuepadProbe }.first { _ in true }
        await process.stop()
        guard let reply else { throw AgentProbe.ProbeError.noAnswer(status: process.status ?? -1) }
        return reply.models.isEmpty ? nil : MacAgent(kind: .dsh, model: reply.model?.key, models: reply.models)
    }
}

/// 起 dsh 的 ACP 服务：`dsh --profile acp --patch <补丁>`。补丁叠在用户的 acp profile 之上（不改它），插入随包插件（`dsh-cuepad.mjs`，
/// 它接管 ACP 的传输、加上 CuePad 要的扩展方法），并关掉：会话记录上传 DeepSeek（`session-log-deepseek`，实测关前每次请求都带着会话记录）、
/// 遥测（`session-telemetry-otel`）、设置与配置编辑器（不往用户的 profile 写；旧版留下的 `settings.yaml` 也不被这次启动导进 acp profile、改名）。
/// 托管会话另插入 `ask_user_question`；大脑只留读文件类工具、整份系统提示换成 Cue 的，存储全进本次运行的临时目录（用完随它删）。
struct DshLaunch {
    let arguments: [String]
    /// 加给 dsh 的环境（在 CuePad 的环境之上）
    let environment: [String: String]

    static let plugin = Bundle.module.url(forResource: "dsh-cuepad", withExtension: "mjs")!

    /// 托管的会话与探测：补丁内容只随 App 的位置变，写在 `<DSH_HOME>/cuepad/acp.yml`（变了才重写）。`model` 是新会话的模型（`提供方/模型`）。
    static func hosted(_ paths: AgentPaths, model: String? = nil) throws -> DshLaunch {
        let home = DshRuntime.home(paths)
        let root = home.appending(path: DshRuntime.sessions, directoryHint: .isDirectory)
        let patch = home.appending(path: "cuepad/acp.yml")
        let text = render(plugin: [:], insert: [askUser], storage: root.deletingLastPathComponent(), sessions: root)
        if (try? String(contentsOf: patch, encoding: .utf8)) != text {
            try FileManager.default.createDirectory(at: patch.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: patch, options: .atomic)
        }
        return DshLaunch(arguments: arguments(patch), environment: environment(home, model: model))
    }

    /// Cue 的大脑：补丁与系统提示写进本次运行的临时目录 `directory`，会话、附件、存储也都在里面。
    static func brain(_ paths: AgentPaths, in directory: URL, prompt: String, model: String?) throws -> DshLaunch {
        let promptFile = directory.appending(path: "prompt.md")
        try Data(prompt.utf8).write(to: promptFile)
        let patch = directory.appending(path: "brain.yml")
        let text = render(plugin: ["prompt": promptFile.path], insert: [], storage: directory, sessions: directory.appending(path: "sessions")) + brainOnly(directory)
        try Data(text.utf8).write(to: patch)
        return DshLaunch(arguments: arguments(patch), environment: environment(DshRuntime.home(paths), model: model))
    }

    private static func arguments(_ patch: URL) -> [String] { ["--profile", "acp", "--patch", patch.path] }

    private static func environment(_ home: URL, model: String?) -> [String: String] {
        [DshRuntime.facts.homeVariable: home.path].merging(model.map { ["CUEPAD_MODEL": $0] } ?? [:]) { $1 }
    }

    private static let askUser = "    - id: tool-ask-user\n      name: '@deepseek-ai/dsh-tool-ask-user'\n"

    private static func render(plugin config: [String: String], insert: [String], storage: URL, sessions: URL) -> String {
        let settings = config.map { "        \($0.key): \(quoted($0.value))\n" }.sorted().joined()
        return """
            - insert:
                - id: cuepad
                  name: \(quoted(plugin.path))
            \(settings.isEmpty ? "" : "      config:\n" + settings)\(insert.joined())- id: acp
              inject: [acpAppStartup, cuepadAcp]
              config:
                stream: !!js ctx.get('cuepadAcp').stream
                provider: !!js ctx.get('cuepadAcp').provider
                model: !!js ctx.get('cuepadAcp').model
            - { id: session-log-deepseek, disabled: true }
            - { id: session-telemetry-otel, disabled: true }
            - { id: settings, disabled: true }
            - { id: config-editor, disabled: true }
            - id: session-persistence-jsonl
              config: { root: \(quoted(sessions.path)), compression: none }
            - id: storage-json
              config: { root: \(quoted(storage.appending(path: "storages").path)) }

            """
    }

    /// 大脑不写代码：只留读文件与搜索，技能、规则、子代理、计划、网页这些都关掉；附件也进临时目录。
    private static func brainOnly(_ directory: URL) -> String {
        let off = [
            "tool-bash", "tool-pwsh", "tool-jobs", "tool-skill", "skill", "skill-filesystem", "agent-instructions", "plan-mode", "goal",
            "goal-round-driver", "command-goal", "tool-goal", "tool-todo", "tool-web", "tool-workflow", "workflow-ptc", "tool-subagent",
            "tool-subagent-fork", "tool-subagent-control", "tool-subagent-list-agents", "tool-working-directory", "tool-plugin-manager",
            "repeat-tool-reminder", "mcp-resources", "session-title",
        ]
        return """
            - id: system-prompt
              config: { includeHarnessIdentity: false, includeRuntimeContext: false }
            - id: tool-fs
              config: { write: false, edit: false }
            - id: attachment-local
              config: { dshHome: \(quoted(directory.path)) }

            """ + off.map { "- { id: \($0), disabled: true }\n" }.joined()
    }

    /// YAML 的单引号字符串：里面的单引号写两遍。
    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}
#endif
