#if os(macOS)
import CryptoKit
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
        releasesIdleHosted: true, probe: askDsh, brain: { ACPSession(dialect: DshDialect()) }, sharedSkills: .topLevel, projectFolder: ".dsh")

    nonisolated static func home(_ paths: AgentPaths) -> URL { paths.directory(facts.homeVariable) ?? paths.user(".dsh") }

    /// CuePad 托管的会话的存储根（在 DSH_HOME 下，明文；理由见 `DshRuntime` 头注释；补丁里的同一个位置见 `DshLaunch`）
    nonisolated static let sessions = "cuepad/sessions"

    /// 起一个不答 ACP 的进程，插件的探测模式（`CUEPAD_PROBE`）把模型清单写成一行就退出：与会话的模型菜单同一份（各提供方的清单），
    /// 缺省是新会话用的模型。一个模型都没有是没登录（没有 key、也没登录账号）。标准输入要一直开着：一关 dsh 就收场，清单还没问完。
    nonisolated private static func askDsh(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        try DshLaunch.prepare(.hosted)
        let environment = probe.locator.environment(
            launching: executable, overrides: probe.paths.environment.merging(DshLaunch.environment(probe.paths, model: nil)) { $1 }.merging(["CUEPAD_PROBE": "1"]) { $1 })
        let process = try await ChildProcess(
            executable, DshLaunch.arguments(.hosted), directory: FileManager.default.temporaryDirectory, environment: environment, placement: .group,
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
/// 它接管 ACP 的传输、补成驱动用的标准样子），并关掉：会话记录上传 DeepSeek（`session-log-deepseek`，实测关前每次请求都带着会话记录）、
/// 遥测（`session-telemetry-otel`）、设置与配置编辑器（不往用户的 profile 写；旧版留下的 `settings.yaml` 也不被这次启动导进 acp profile、改名）。
/// 大脑另只留读文件类工具、整份系统提示换成 Cue 的，存储全进本次运行的临时目录（用完随它删）。
/// 两份补丁的内容只随 App 的位置变：随时用到随时写在临时目录里（变了才重写），各次运行的不同经环境给（`!!js process.env`）。
enum DshLaunch {
    enum Patch: String {
        case hosted, brain
    }

    static let plugin = Bundle.module.url(forResource: "dsh-cuepad", withExtension: "mjs")!
    /// 按插件的位置分开：同时开着的两份 App（本机构建与正式版）各用各的。写成 UUID 的样子：录像带比对启动参数时不算它
    private static let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-dsh-" + uuid(plugin.path), directoryHint: .isDirectory)

    private static func uuid(_ text: String) -> String {
        let b = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    static func arguments(_ patch: Patch) -> [String] { ["--profile", "acp", "--patch", file(patch).path] }

    /// 写好这份补丁（内容变了才重写）。
    static func prepare(_ patch: Patch) throws {
        let text = patch == .hosted ? hosted : brain
        guard (try? String(contentsOf: file(patch), encoding: .utf8)) != text else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file(patch), options: .atomic)
    }

    /// 托管会话与探测的环境：配置目录（`DSH_HOME`）与新会话的模型（`提供方/模型`，插件的 `CUEPAD_MODEL`）。
    static func environment(_ paths: AgentPaths, model: String?) -> [String: String] {
        [DshRuntime.facts.homeVariable: DshRuntime.home(paths).path].merging(model.map { ["CUEPAD_MODEL": $0] } ?? [:]) { $1 }
    }

    /// 大脑的环境：本次运行的临时目录（会话、附件、存储都在里面）与写在里面的系统提示。
    static func brainEnvironment(in run: URL, prompt: String, model: String?) throws -> [String: String] {
        let promptFile = run.appending(path: "prompt.md")
        try Data(prompt.utf8).write(to: promptFile)
        return ["CUEPAD_BRAIN_DIR": run.path, "CUEPAD_PROMPT": promptFile.path].merging(model.map { ["CUEPAD_MODEL": $0] } ?? [:]) { $1 }
    }

    private static func file(_ patch: Patch) -> URL { directory.appending(path: patch.rawValue + ".yml") }

    private static var hosted: String {
        common(prompt: false, storage: "dshHomePath('cuepad')")
    }

    /// 大脑不写代码：只留读文件与搜索，技能、规则、子代理、计划、网页这些都关掉；附件也进临时目录。
    private static var brain: String {
        let off = [
            "tool-bash", "tool-pwsh", "tool-jobs", "tool-skill", "skill", "skill-filesystem", "agent-instructions", "plan-mode", "goal",
            "goal-round-driver", "command-goal", "tool-goal", "tool-todo", "tool-web", "tool-workflow", "workflow-ptc", "tool-subagent",
            "tool-subagent-fork", "tool-subagent-control", "tool-subagent-list-agents", "tool-working-directory", "tool-plugin-manager",
            "repeat-tool-reminder", "mcp-resources", "session-title",
        ]
        return common(prompt: true, storage: "process.env.CUEPAD_BRAIN_DIR") + """
            - id: system-prompt
              config: { includeHarnessIdentity: false, includeRuntimeContext: false }
            - id: tool-fs
              config: { write: false, edit: false }
            - id: attachment-local
              config: { dshHome: !!js process.env.CUEPAD_BRAIN_DIR }

            """ + off.map { "- { id: \($0), disabled: true }\n" }.joined()
    }

    /// 两份都有的：插件接管传输、关掉上传与写用户的 profile、会话存进 `storage` 下的明文根（JS 表达式）。
    private static func common(prompt: Bool, storage: String) -> String {
        """
        - insert:
            - id: cuepad
              name: \(quoted(plugin.path))
        \(prompt ? "      config: { prompt: !!js process.env.CUEPAD_PROMPT }\n" : "")- id: acp
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
          config: { root: !!js "\(storage) + '/sessions'", compression: none }
        - id: storage-json
          config: { root: !!js "\(storage) + '/storages'" }

        """
    }

    /// YAML 的单引号字符串：里面的单引号写两遍。
    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}
#endif
