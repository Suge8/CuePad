#if os(macOS)
import CueStore
import Foundation

/// `status` 没有任何副作用；写入只发生在 `install`，调用方要先征得用户同意。
/// 写入不做事务：哪一样没写上，状态就是 `outdated`，下次启动的静默升级补上。
/// CuePad 起的 OpenCode 服务不读 `.claude/skills`（`OpenCodeRuntime.serviceEnvironment`），同一个技能不会经两条路读到。
public struct AgentIntegration: Sendable {
    public let fileAccess: AgentFileAccess
    var paths: AgentPaths { fileAccess.paths }
    private var pi: PiPaths { paths.pi }
    let locate: @Sendable () async -> ExecutableLocator
    private let cuepad: URL
    let installCommand: @Sendable (AgentKind, AgentStatus.Presence) -> String
    /// 起一个进程要多久取决于系统此刻多忙，测试给手动推进的钟
    private let timing: Timing

    public init(
        paths: AgentPaths = AgentPaths(), locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, cuepad: URL,
        isolated: Bool = false, installCommand: @escaping @Sendable (AgentKind, AgentStatus.Presence) -> String = { $0.facts.installCommand($1) },
        timing: Timing = .system
    ) {
        self.timing = timing
        fileAccess = AgentFileAccess(paths: paths, isolated: isolated)
        self.locate = locate
        self.cuepad = cuepad
        self.installCommand = installCommand
    }

    public func home(of kind: AgentKind) -> URL { paths.home(of: kind) }

    public func isWritable(_ kind: AgentKind) -> Bool { touches(kind) && touchesShared }

    public func touches(_ kind: AgentKind) -> Bool { fileAccess.touches(kind) }

    public var touchesShared: Bool { fileAccess.touchesShared }

    private static func linksSkill(_ kind: AgentKind) -> Bool { !kind.facts.sharedSkills.reaches(group: "") }

    var skillDirectory: URL { paths.agentsDirectory.appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory) }
    var skillFile: URL { skillDirectory.appending(path: AgentSkill.fileName) }
    func agentSkillDirectory(_ kind: AgentKind) -> URL { home(of: kind).appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory) }

    public func writtenFiles(of kind: AgentKind) -> [URL] {
        [skillFile] + (Self.linksSkill(kind) ? [agentSkillDirectory(kind)] : [])
    }

    @concurrent public func status(of kind: AgentKind) async -> AgentStatus {
        let found = await detect(kind)
        let lacking = found.presence == .notFound ? await lacking(kind.facts.installPrerequisite) : nil
        return AgentStatus(presence: found.presence, files: skillState(of: kind), executable: found.executable, lacking: lacking)
    }

    /// 隔离运行写不了、Agent 不在或太旧、或同名文件不是 CuePad 写的时拒绝，且什么都不写。
    @concurrent public func install(_ kind: AgentKind) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        let found = await detect(kind)
        switch found.presence {
        case .notFound: throw AgentInstallError.notFound(kind)
        case .unresponsive: throw AgentInstallError.unresponsive(kind)
        case .tooOld(let version): throw AgentInstallError.tooOld(kind, found: version)
        case .found: break
        }
        if case .foreign(let path) = skillState(of: kind) { throw AgentInstallError.foreign(path) }
        try writeSkill(for: connectedKinds.union([kind]))
    }

    /// Agent 已经卸掉了也能删；隔离运行写不了、有别人的同名文件时什么都不删。
    @concurrent public func uninstall(_ kind: AgentKind) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        if case .foreign(let path) = skillState(of: kind) { throw AgentInstallError.foreign(path) }
        let left = connectedKinds.subtracting([kind])
        if Self.linksSkill(kind), RelativeLink.isLink(agentSkillDirectory(kind)) { try FileManager.default.removeItem(at: agentSkillDirectory(kind)) }
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

    private var connectedKinds: Set<AgentKind> { read(skillFile).flatMap(AgentSkill.kinds(in:)) ?? [] }

    private func writeSkill(for kinds: Set<AgentKind>) throws {
        let files = FileManager.default
        try files.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data(AgentSkill.text(cuepad: cuepad, for: kinds).utf8).write(to: skillFile, options: .atomic)
        for kind in kinds where Self.linksSkill(kind) {
            let link = agentSkillDirectory(kind)
            guard !RelativeLink.points(link, to: skillDirectory) else { continue }
            if RelativeLink.isLink(link) { try files.removeItem(at: link) }
            try RelativeLink.make(at: link, to: skillDirectory)
        }
    }

    @concurrent public func probe(_ statuses: [AgentKind: AgentStatus]) async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        await AgentProbe(paths: paths, locator: await locate(), timing: timing).run(statuses)
    }

    private func skillState(of kind: AgentKind) -> AgentStatus.Files {
        let skill = read(skillFile)
        if skill.map({ AgentSkill.kinds(in: $0) == nil }) ?? unreadable(skillFile) { return .foreign(abbreviated(skillFile)) }
        let own = agentSkillDirectory(kind)
        if !RelativeLink.isLink(own), FileManager.default.fileExists(atPath: own.path) { return .foreign(abbreviated(own)) }
        let linked = !Self.linksSkill(kind) || RelativeLink.points(own, to: skillDirectory)
        if RelativeLink.isLink(own), !linked { return .foreign(abbreviated(own)) }
        let kinds = skill.flatMap(AgentSkill.kinds(in:)) ?? []
        guard kinds.contains(kind) else { return .missing }
        return skill == AgentSkill.text(cuepad: cuepad, for: kinds) && linked ? .current : .outdated
    }

    private func abbreviated(_ file: URL) -> String { UserHome.shown(file.path) }

    private func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 不是 CuePad 写的，不当成缺失去覆盖；不跟随符号链接，失效的链接也算在。
    private func unreadable(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil && read(file) == nil
    }

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

    /// 脚本按 PATH 取第一个（`command -v`），它的 PATH 是 /bin 之后紧跟找 Agent 的同一组目录
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

    /// 数据目录给一个用完即删的临时目录：OpenCode 每次运行（`--version` 也是）都往
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
