#if os(macOS)
import CueStore
import Foundation

/// CuePad 接入各个 Agent：检测、安装、升级与卸载它们的技能与上报通道（Pi 是桥扩展，Claude Code、Codex 是钩子；OpenCode 直连它的服务，不用装），一起装、一起升级。
/// `status` 没有任何副作用；写入只发生在 `install`，调用方要先征得用户同意；`uninstall` 删掉 CuePad 写的全部文件和因此空出来的目录。
/// 技能只写进每个 Agent 自己的配置目录（`<目录>/skills/cuepad/SKILL.md`），不写几家共用的 `~/.agents/skills`：
/// 那里是用户自己维护的，且会被好几家同时读到。OpenCode 也读 `~/.claude/skills`，两份同名同内容，按名字去重。
/// 写入不做事务：哪一样没写上，状态就是 `outdated`，下次启动的静默升级补上。
public struct AgentIntegration: Sendable {
    let paths: AgentPaths
    private var pi: PiPaths { paths.pi }
    let locate: @Sendable () async -> ExecutableLocator
    /// App 里的命令行工具（`Contents/Helpers/cuepad`），技能里写它的绝对路径
    private let cuepad: URL
    /// 隔离运行（开发构建）：配置目录是缺省真实位置的那几家只检测、不写
    private let isolated: Bool
    /// 装一家用的命令（`runInstaller`）：官方的那条，测试换成放替身的
    let installCommand: @Sendable (AgentKind, AgentStatus.Presence) -> String
    /// 还有 Pi 会话开着旧单文件扩展（`PiExtensionBundle.legacyFileName`）：App 里是桥上连着的会话没都报随包版本（`PiBridge.allRun`），缺省没有 Pi 在跑
    let legacyPiExtensionInUse: @Sendable () async -> Bool

    public init(
        paths: AgentPaths = AgentPaths(), locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, cuepad: URL,
        isolated: Bool = false, installCommand: @escaping @Sendable (AgentKind, AgentStatus.Presence) -> String = { $0.installCommand($1) },
        legacyPiExtensionInUse: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.paths = paths
        self.locate = locate
        self.cuepad = cuepad
        self.isolated = isolated
        self.installCommand = installCommand
        self.legacyPiExtensionInUse = legacyPiExtensionInUse
    }

    public func home(of kind: AgentKind) -> URL { paths.home(of: kind) }

    /// 能不能写这家：隔离运行而它的配置目录就是缺省的真实位置（没经环境变量或参数换走）时不能。
    public func isWritable(_ kind: AgentKind) -> Bool {
        !isolated || home(of: kind).standardizedFileURL != AgentPaths(pi: PiPaths(environment: [:]), environment: [:]).home(of: kind).standardizedFileURL
    }

    /// Claude Code、Codex 的钩子配置（其余没有钩子）。
    /// `codex` 是写、删信任时起的 `codex`（检测时挑中的那个）；只看状态时不用。
    func hooks(_ kind: AgentKind, codex: URL? = nil) -> (any AgentHookConfig)? {
        switch kind {
        case .claudeCode: HookFile.claudeCode(home: home(of: kind), skillDirectory: skillDirectory(of: kind))
        case .codex:
            CodexHooks(home: home(of: kind), skillDirectory: skillDirectory(of: kind), codex: codex, locate: locate, environment: paths.environment)
        case .pi, .opencode: nil
        }
    }

    /// 写进钩子配置的命令：App 里 `cuepad` 的绝对路径（App 被移动后它变了，钩子就成了旧版，启动时重写）。
    func hookCommand(_ kind: AgentKind) -> String { "\(AgentSkill.shellQuoted(cuepad.path)) hook \(kind.rawValue)" }

    private func skillDirectory(of kind: AgentKind) -> URL {
        home(of: kind).appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory)
    }

    func skillFile(_ kind: AgentKind) -> URL { skillDirectory(of: kind).appending(path: AgentSkill.fileName) }
    private var piExtension: PiExtensionFiles { PiExtensionFiles(extensionsDirectory: pi.extensionsDirectory) }

    /// CuePad 写给这家的文件：技能，Pi 的扩展，钩子配置（只改其中 CuePad 的条目）。界面据此说明会写哪里。
    public func writtenFiles(of kind: AgentKind) -> [URL] {
        [skillFile(kind)] + (kind == .pi ? [piExtension.directory] : []) + (hooks(kind)?.writtenFiles ?? [])
    }

    @concurrent public func status(of kind: AgentKind) async -> AgentStatus {
        let found = await detect(kind)
        let lacking = found.presence == .notFound ? await lacking(kind.installPrerequisite) : nil
        return AgentStatus(presence: found.presence, files: files(of: kind), executable: found.executable, lacking: lacking)
    }

    /// 写入（新装或升级）。隔离运行写不了、Agent 不在或太旧、或同名文件不是 CuePad 写的时拒绝，且什么都不写。
    @concurrent public func install(_ kind: AgentKind) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        let found = await detect(kind)
        switch found.presence {
        case .notFound: throw AgentInstallError.notFound(kind)
        case .tooOld(let version): throw AgentInstallError.tooOld(kind, found: version)
        case .found: break
        }
        if case .foreign(let path) = files(of: kind) { throw AgentInstallError.foreign(path) }
        if kind == .pi { try piExtension.install(legacyInUse: await legacyPiExtensionInUse()) }
        try FileManager.default.createDirectory(at: skillDirectory(of: kind), withIntermediateDirectories: true)
        try Data(AgentSkill.text(for: kind, cuepad: cuepad).utf8).write(to: skillFile(kind), options: .atomic)
        try await hooks(kind, codex: found.executable)?.install(command: hookCommand(kind))
    }

    /// 删掉 CuePad 写给这个 Agent 的全部文件，以及因此空出来的目录（`skills/cuepad`，空了的 `skills`、`extensions`）。
    /// Agent 已经卸掉了也能删；隔离运行写不了、有别人的同名文件时什么都不删。`executable` 是检测时挑中的那个（`AgentStatus.executable`）：
    /// Codex 删信任要起它，其余不用。
    /// 过渡：旧单文件扩展的存根没有会话再用时删掉（见 `PiExtensionBundle.legacyFileName`）。App 在 Pi 会话上线、下线与启动检查时调。
    @concurrent public func retireLegacyPiExtension() async throws {
        guard isWritable(.pi) else { return }
        try piExtension.retireLegacyFile(inUse: await legacyPiExtensionInUse())
    }

    @concurrent public func uninstall(_ kind: AgentKind, executable: URL? = nil) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        if case .foreign(let path) = files(of: kind) { throw AgentInstallError.foreign(path) }
        try await hooks(kind, codex: executable)?.uninstall()
        if FileManager.default.fileExists(atPath: skillFile(kind).path) { try FileManager.default.removeItem(at: skillFile(kind)) }
        if kind == .pi { try piExtension.uninstall() }
        var directories = [skillDirectory(of: kind), skillDirectory(of: kind).deletingLastPathComponent()]
        if kind == .pi { directories.append(pi.extensionsDirectory) }
        for directory in directories where (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 由检测出的状态（`status(of:)`）得出这台 Mac 上各家能不能用：能开新会话的几家问模型，其余给出原因（`AgentProbe`）。
    @concurrent public func probe(_ statuses: [AgentKind: AgentStatus]) async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        await AgentProbe(paths: paths, locator: await locate()).run(statuses)
    }

    private func files(of kind: AgentKind) -> AgentStatus.Files {
        let skill = read(skillFile(kind))
        if skill.map({ !$0.contains(AgentSkill.ownershipMarker) }) ?? unreadable(skillFile(kind)) { return .foreign(abbreviated(skillFile(kind))) }
        let skillState: AgentStatus.Files = skill.map { $0 == AgentSkill.text(for: kind, cuepad: cuepad) ? .current : .outdated } ?? .missing
        let other: AgentStatus.Files
        if kind == .pi {
            other = piExtension.state
            if case .foreign = other { return other }
        } else {
            other = hooks(kind)?.files(command: hookCommand(kind)) ?? skillState
        }
        switch (skillState, other) {
        case (.missing, .missing): return .missing
        case (.current, .current): return .current
        default: return .outdated
        }
    }

    private func abbreviated(_ file: URL) -> String { (file.path as NSString).abbreviatingWithTildeInPath }

    private func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 文件在却读不出或不是 UTF-8 文本：不是 CuePad 写的，不当成缺失去覆盖（不跟随符号链接：失效的链接也算在）。
    private func unreadable(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil && read(file) == nil
    }

    /// 问每家的 `--version`（设置里写出版本）：有版本要求的（Pi、OpenCode）要报得出够新的版本，OpenCode 报的版本太旧是 v1；
    /// 报不出版本的照常算在，只是没有版本。没有可执行文件时，除了 Pi，有配置目录（用过它，含各家的桌面版）也算在。
    /// 挑中的可执行文件只在算在时给出（太旧的不给）。
    private func detect(_ kind: AgentKind) async -> (presence: AgentStatus.Presence, executable: URL?) {
        let locator = await locate()
        let used = FileManager.default.fileExists(atPath: home(of: kind).path)
        let candidates = locator.candidates(kind.command)
        for executable in candidates {
            guard let output = await Self.capture(executable, ["--version"], locator: locator),
                  let version = AgentVersion(parsing: output) else { continue }
            let tooOld = kind.minimumVersion.map { version < $0 } ?? false
            return tooOld ? (.tooOld(version), nil) : (.found(version), executable)
        }
        if kind.minimumVersion == nil, let executable = candidates.first { return (.found(nil), executable) }
        return (kind != .pi && used ? .found(nil) : .notFound, nil)
    }

    /// 安装脚本会用的那个程序够不够新；够为 nil。脚本按 PATH 取第一个（`command -v`），它的 PATH 是 /bin 之后紧跟找 Agent 的同一组目录
    /// （`runInstaller`、`ExecutableLocator.environment`），所以只看这组目录里的第一个：后面有新的也不算。
    private func lacking(_ prerequisite: InstallPrerequisite?) async -> InstallPrerequisite? {
        guard let prerequisite else { return nil }
        let locator = await locate()
        guard let executable = locator.candidates(prerequisite.command).first,
              let output = await Self.capture(executable, ["--version"], locator: locator),
              let version = AgentVersion(parsing: output), version >= prerequisite.minimum else { return prerequisite }
        return nil
    }

    /// 运行并取标准输出；超时或无法启动返回 nil。数据目录给一个用完即删的临时目录：OpenCode 每次运行（`--version` 也是）都往
    /// `$XDG_DATA_HOME/opencode/log` 写日志，不能写进用户的。不运行就读出版本的办法没有通用的：npm 包有 package.json，
    /// Homebrew 与官方脚本装的是裸可执行文件，v2 的里面嵌着版本、v1 的没有同样的标记。
    private static func capture(_ executable: URL, _ arguments: [String], locator: ExecutableLocator, timeout: Duration = .seconds(10)) async -> String? {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "cuepad-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let environment = locator.environment(launching: executable, overrides: ["PI_OFFLINE": "1", "XDG_DATA_HOME": scratch.path])
        return await ChildProcess.run(executable, arguments, environment: environment, timeout: timeout)?.output
    }
}
#endif
