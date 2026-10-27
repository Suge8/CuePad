#if os(macOS)
import CueStore
import Foundation

/// CuePad 接入各个 Agent：检测、安装、升级与卸载它们的技能与上报通道（`AgentFacts.channel`：Pi 是桥扩展，Claude Code、Codex 是钩子；
/// OpenCode 直连它的服务，不用装），一起装、一起升级。
/// `status` 没有任何副作用；写入只发生在 `install`，调用方要先征得用户同意；`uninstall` 删掉 CuePad 写的全部文件和因此空出来的目录。
/// 技能只写一份，在几家共读的 `~/.agents/skills/cuepad`；不读 `.agents` 的（`AgentFacts.readsSharedSkills`，Claude Code）
/// 另有一个相对链接 `<它的目录>/skills/cuepad` 指到那里。各家接没接入记在技能的标记行里（`AgentSkill.kinds(in:)`）。
/// 钩子的足迹（`HookFile.Footprint`）也放在那个目录里。旧版写在各家自己目录里、带标记的副本，装或升级任何一家时一起收掉
/// （它们的那家记进标记行，足迹搬过来），所以旧版接入过的几家状态是 `outdated`、由静默升级换过来。
/// 这是过渡：用户的 Mac 都装过一次带技能与规则（结构 76）起的 CuePad 并启动过后，连同 `legacyCopies` 与搬足迹那一段一起删。
/// CuePad 起的 OpenCode 服务不读 `.claude/skills`（`OpenCodeRuntime.serviceEnvironment`），同一个技能不会经两条路读到。
/// 写入不做事务：哪一样没写上，状态就是 `outdated`，下次启动的静默升级补上。
public struct AgentIntegration: Sendable {
    let paths: AgentPaths
    private var pi: PiPaths { paths.pi }
    let locate: @Sendable () async -> ExecutableLocator
    /// App 里的命令行工具（`Contents/Helpers/cuepad`），技能里写它的绝对路径
    private let cuepad: URL
    /// 不碰真实世界（App 层的 `touchesRealWorld` 为 false）：配置目录是缺省真实位置的那几家只检测、不写
    private let isolated: Bool
    /// 装一家用的命令（`runInstaller`）：官方的那条，测试换成放替身的
    let installCommand: @Sendable (AgentKind, AgentStatus.Presence) -> String
    /// 还有 Pi 会话开着旧单文件扩展（`PiExtensionBundle.legacyFileName`）：App 里是桥上连着的会话没都报随包版本（`PiBridge.allRun`），缺省没有 Pi 在跑
    let legacyPiExtensionInUse: @Sendable () async -> Bool
    /// 量问版本、问模型这些等别的进程的时限的钟：起一个进程要多久取决于系统此刻多忙，测试给手动推进的钟
    private let timing: Timing

    public init(
        paths: AgentPaths = AgentPaths(), locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, cuepad: URL,
        isolated: Bool = false, installCommand: @escaping @Sendable (AgentKind, AgentStatus.Presence) -> String = { $0.facts.installCommand($1) },
        legacyPiExtensionInUse: @escaping @Sendable () async -> Bool = { false }, timing: Timing = .system
    ) {
        self.timing = timing
        self.paths = paths
        self.locate = locate
        self.cuepad = cuepad
        self.isolated = isolated
        self.installCommand = installCommand
        self.legacyPiExtensionInUse = legacyPiExtensionInUse
    }

    public func home(of kind: AgentKind) -> URL { paths.home(of: kind) }

    /// 能不能写这家：隔离运行而它的配置目录或几家共读的目录（技能写在那里）是缺省的真实位置（没经环境变量或参数换走）时不能。
    public func isWritable(_ kind: AgentKind) -> Bool { touches(kind) && touchesShared }

    /// 能碰这家的配置目录（读写技能与规则，`AgentLibraryFiles` 也按它）。
    public func touches(_ kind: AgentKind) -> Bool { !isolated || home(of: kind).standardizedFileURL != Self.real.home(of: kind).standardizedFileURL }

    /// 能碰几家共读的 `~/.agents`。
    public var touchesShared: Bool { !isolated || paths.agentsDirectory.standardizedFileURL != Self.real.agentsDirectory.standardizedFileURL }

    private static let real = AgentPaths(pi: PiPaths(environment: [:]), environment: [:])

    /// 这家的上报通道（`AgentFacts.channel`）。`executable` 是写、删时起的那个（检测时挑中的，Codex 写、删信任要它）；只看状态时不用。
    func channel(_ kind: AgentKind, executable: URL? = nil) -> (any AgentHookConfig)? { kind.facts.channel(self, executable) }

    /// 写进钩子配置的命令：App 里 `cuepad` 的绝对路径（App 被移动后它变了，钩子就成了旧版，启动时重写）。
    func hookCommand(_ kind: AgentKind) -> String { "\(AgentSkill.shellQuoted(cuepad.path)) hook \(kind.rawValue)" }

    /// 那一份技能的目录（`~/.agents/skills/cuepad`）。
    var skillDirectory: URL { paths.agentsDirectory.appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory) }
    var skillFile: URL { skillDirectory.appending(path: AgentSkill.fileName) }
    /// 不读 `.agents` 的那家的技能链接；也是旧版各家副本所在的位置（`<各家目录>/skills/cuepad`）。
    func agentSkillDirectory(_ kind: AgentKind) -> URL { home(of: kind).appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory) }
    private var piExtension: PiExtensionFiles { PiExtensionFiles(extensionsDirectory: pi.extensionsDirectory, legacyInUse: legacyPiExtensionInUse) }

    /// CuePad 写给这家的文件：技能（不读 `.agents` 的另有链接），上报通道（钩子配置只改其中 CuePad 的条目）。界面据此说明会写哪里。
    public func writtenFiles(of kind: AgentKind) -> [URL] {
        [skillFile] + (kind.facts.readsSharedSkills ? [] : [agentSkillDirectory(kind)]) + (channel(kind)?.writtenFiles ?? [])
    }

    @concurrent public func status(of kind: AgentKind) async -> AgentStatus {
        let found = await detect(kind)
        let lacking = found.presence == .notFound ? await lacking(kind.facts.installPrerequisite) : nil
        return AgentStatus(presence: found.presence, files: files(of: kind), executable: found.executable, lacking: lacking)
    }

    /// 写入（新装或升级）。隔离运行写不了、Agent 不在或太旧、或同名文件不是 CuePad 写的时拒绝，且什么都不写。
    @concurrent public func install(_ kind: AgentKind) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        let found = await detect(kind)
        switch found.presence {
        case .notFound: throw AgentInstallError.notFound(kind)
        case .unresponsive: throw AgentInstallError.unresponsive(kind)
        case .tooOld(let version): throw AgentInstallError.tooOld(kind, found: version)
        case .found: break
        }
        if case .foreign(let path) = files(of: kind) { throw AgentInstallError.foreign(path) }
        try writeSkill(for: connectedKinds.union([kind]).union(legacyCopies))
        try await channel(kind, executable: found.executable)?.install(command: hookCommand(kind))
    }

    /// 删掉 CuePad 写给这个 Agent 的全部文件，以及因此空出来的目录（`skills/cuepad`，空了的 `skills`、Pi 的 `extensions`）。
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
        if legacyCopies.contains(kind) { try writeSkill(for: connectedKinds.union(legacyCopies)) }  // 先把足迹搬过来，钩子才删得干净
        try await channel(kind, executable: executable)?.uninstall()
        let left = connectedKinds.subtracting([kind])
        if !kind.facts.readsSharedSkills, RelativeLink.isLink(agentSkillDirectory(kind)) { try FileManager.default.removeItem(at: agentSkillDirectory(kind)) }
        if left.isEmpty {
            if FileManager.default.fileExists(atPath: skillFile.path) { try FileManager.default.removeItem(at: skillFile) }
        } else {
            try writeSkill(for: left)
        }
        let directories = [skillDirectory, skillDirectory.deletingLastPathComponent(), paths.agentsDirectory, agentSkillDirectory(kind).deletingLastPathComponent()]
        for directory in directories where (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 标记行里接入的几家（没有那份技能、或不是 CuePad 写的为空）。
    private var connectedKinds: Set<AgentKind> { read(skillFile).flatMap(AgentSkill.kinds(in:)) ?? [] }

    /// 还留着旧版副本（各家目录里带标记的 `skills/cuepad`，不是链接）的几家，只看写得了的。
    private var legacyCopies: Set<AgentKind> {
        Set(AgentKind.allCases.filter { kind in
            let directory = agentSkillDirectory(kind)
            return touches(kind) && !RelativeLink.isLink(directory) && read(directory.appending(path: AgentSkill.fileName)).flatMap(AgentSkill.kinds(in:)) != nil
        })
    }

    /// 把那一份技能写成为 `kinds` 接入的样子：收掉旧版副本（足迹搬过来），补上其中不读 `.agents` 的几家的链接。
    private func writeSkill(for kinds: Set<AgentKind>) throws {
        let files = FileManager.default
        try files.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data(AgentSkill.text(cuepad: cuepad, for: kinds).utf8).write(to: skillFile, options: .atomic)
        for kind in legacyCopies {
            let legacy = agentSkillDirectory(kind)
            for footprint in (try? files.contentsOfDirectory(atPath: legacy.path)) ?? [] where footprint.hasSuffix("-hooks.json") {
                let moved = skillDirectory.appending(path: footprint)
                if !files.fileExists(atPath: moved.path) { try files.moveItem(at: legacy.appending(path: footprint), to: moved) }
            }
            try files.removeItem(at: legacy)
        }
        for kind in kinds where !kind.facts.readsSharedSkills {
            let link = agentSkillDirectory(kind)
            guard !RelativeLink.points(link, to: skillDirectory) else { continue }
            if RelativeLink.isLink(link) { try files.removeItem(at: link) }
            try RelativeLink.make(at: link, to: skillDirectory)
        }
    }

    /// 由检测出的状态（`status(of:)`）得出这台 Mac 上各家能不能用：能开新会话的几家问模型，其余给出原因（`AgentProbe`）。
    @concurrent public func probe(_ statuses: [AgentKind: AgentStatus]) async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        await AgentProbe(paths: paths, locator: await locate(), timing: timing).run(statuses)
    }

    /// 技能这一样：标记行里有这家，内容是这个版本要写的、旧副本收掉了、要链接的链接在，才是 `current`；
    /// 只有旧版副本是 `outdated`。同名的不是 CuePad 写的（那一份、旧副本的位置上、链接的位置上）是 `foreign`。
    private func skillState(of kind: AgentKind) -> AgentStatus.Files {
        let skill = read(skillFile)
        if skill.map({ AgentSkill.kinds(in: $0) == nil }) ?? unreadable(skillFile) { return .foreign(abbreviated(skillFile)) }
        let own = agentSkillDirectory(kind), ownFile = own.appending(path: AgentSkill.fileName)
        let legacy = !RelativeLink.isLink(own) && FileManager.default.fileExists(atPath: own.path)
        if legacy, read(ownFile).flatMap(AgentSkill.kinds(in:)) == nil { return .foreign(abbreviated(own)) }
        let linked = kind.facts.readsSharedSkills || RelativeLink.points(own, to: skillDirectory)
        if RelativeLink.isLink(own), !linked { return .foreign(abbreviated(own)) }
        let kinds = skill.flatMap(AgentSkill.kinds(in:)) ?? []
        guard kinds.contains(kind) else { return legacy ? .outdated : .missing }
        return skill == AgentSkill.text(cuepad: cuepad, for: kinds) && !legacy && linked ? .current : .outdated
    }

    private func files(of kind: AgentKind) -> AgentStatus.Files {
        let skillState = skillState(of: kind)
        if case .foreign = skillState { return skillState }
        let other = channel(kind)?.files(command: hookCommand(kind)) ?? skillState
        if case .foreign = other { return other }
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

    /// 问每家的 `--version`（设置里写出版本）：有版本要求的（`AgentFacts.minimumVersion`）要报得出够新的版本；
    /// 报不出版本的照常算在，只是没有版本。没有可执行文件时看 `AgentFacts.homeMeansInstalled`。
    /// 挑中的可执行文件只在算在时给出（太旧的不给）。找到了程序却在 `AgentTimeouts.command` 内没回答（机器很忙时常有）：
    /// 说 `unresponsive`，不当成没装。
    private func detect(_ kind: AgentKind) async -> (presence: AgentStatus.Presence, executable: URL?) {
        let locator = await locate()
        let used = FileManager.default.fileExists(atPath: home(of: kind).path)
        let candidates = locator.candidates(kind.facts.command)
        var silent = false
        for executable in candidates {
            switch await capture(executable, ["--version"], locator: locator) {
            case .finished(_, let output):
                guard let version = AgentVersion(parsing: output) else { continue }
                let tooOld = kind.facts.minimumVersion.map { version < $0 } ?? false
                return tooOld ? (.tooOld(version), nil) : (.found(version), executable)
            case .timedOut: silent = true
            case .notStarted: continue
            }
        }
        if kind.facts.minimumVersion == nil, let executable = candidates.first { return (.found(nil), executable) }
        if silent { return (.unresponsive, nil) }
        return (kind.facts.homeMeansInstalled && used ? .found(nil) : .notFound, nil)
    }

    /// 安装脚本会用的那个程序够不够新；够为 nil。脚本按 PATH 取第一个（`command -v`），它的 PATH 是 /bin 之后紧跟找 Agent 的同一组目录
    /// （`runInstaller`、`ExecutableLocator.environment`），所以只看这组目录里的第一个：后面有新的也不算。
    private func lacking(_ prerequisite: InstallPrerequisite?) async -> InstallPrerequisite? {
        guard let prerequisite else { return nil }
        let locator = await locate()
        guard let executable = locator.candidates(prerequisite.command).first else { return prerequisite }
        switch await capture(executable, ["--version"], locator: locator) {
        case .finished(_, let output): return AgentVersion(parsing: output).map { $0 >= prerequisite.minimum } == true ? nil : prerequisite
        case .timedOut: return nil  // 没问出来：不说它缺
        case .notStarted: return prerequisite
        }
    }

    /// 运行并取标准输出。数据目录给一个用完即删的临时目录：OpenCode 每次运行（`--version` 也是）都往
    /// `$XDG_DATA_HOME/opencode/log` 写日志，不能写进用户的。不运行就读出版本的办法没有通用的：npm 包有 package.json，
    /// Homebrew 与官方脚本装的是裸可执行文件，v2 的里面嵌着版本、v1 的没有同样的标记。
    private func capture(_ executable: URL, _ arguments: [String], locator: ExecutableLocator) async -> ChildProcess.Attempt {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "cuepad-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let environment = locator.environment(launching: executable, overrides: ["PI_OFFLINE": "1", "XDG_DATA_HOME": scratch.path])
        return await ChildProcess.attempt(executable, arguments, environment: environment, timeout: AgentTimeouts.command, timing: timing)
    }
}
#endif
