#if os(macOS)
import CueStore
import Foundation

public struct AgentIntegration: Sendable {
    public let fileAccess: AgentFileAccess
    var paths: AgentPaths { fileAccess.paths }
    private var pi: PiPaths { paths.pi }
    let locate: @Sendable () async -> ExecutableLocator
    let installCommand: @Sendable (AgentKind, AgentStatus.Presence) -> String
    private let timing: Timing

    public init(
        paths: AgentPaths = AgentPaths(), locate: @escaping @Sendable () async -> ExecutableLocator = { await .system },
        isolated: Bool = false, installCommand: @escaping @Sendable (AgentKind, AgentStatus.Presence) -> String = { $0.facts.installCommand($1) },
        timing: Timing = .system
    ) {
        self.timing = timing
        fileAccess = AgentFileAccess(paths: paths, isolated: isolated)
        self.locate = locate
        self.installCommand = installCommand
    }

    public func home(of kind: AgentKind) -> URL { paths.home(of: kind) }

    public func touches(_ kind: AgentKind) -> Bool { fileAccess.touches(kind) }

    @concurrent public func status(of kind: AgentKind) async -> AgentStatus {
        let found = await detect(kind)
        let lacking = found.presence == .notFound ? await lacking(kind.facts.installPrerequisite) : nil
        return AgentStatus(presence: found.presence, executable: found.executable, lacking: lacking)
    }

    private var legacySkillDirectory: URL { paths.agentsDirectory.appending(path: "skills/\(AgentSkill.legacyName)", directoryHint: .isDirectory) }
    private var legacySkillFile: URL { legacySkillDirectory.appending(path: AgentSkill.fileName) }
    private func legacyLink(_ kind: AgentKind) -> URL { home(of: kind).appending(path: "skills/\(AgentSkill.legacyName)", directoryHint: .isDirectory) }

    public func legacySkillKinds() -> Set<AgentKind>? {
        guard fileAccess.touchesShared,
              (try? FileManager.default.attributesOfItem(atPath: legacySkillFile.path)[.type] as? FileAttributeType) == .typeRegular,
              let text = (try? Data(contentsOf: legacySkillFile)).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return AgentSkill.kinds(in: text)
    }

    public func removeLegacySkill() throws {
        let files = FileManager.default
        var emptied = [legacySkillDirectory, legacySkillDirectory.deletingLastPathComponent(), paths.agentsDirectory]
        for kind in AgentKind.allCases where touches(kind) && RelativeLink.points(legacyLink(kind), to: legacySkillDirectory) {
            try files.removeItem(at: legacyLink(kind))
            emptied.append(legacyLink(kind).deletingLastPathComponent())
        }
        try files.removeItem(at: legacySkillFile)
        for directory in emptied where (try? files.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? files.removeItem(at: directory)
        }
    }

    @concurrent public func probe(_ statuses: [AgentKind: AgentStatus]) async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        await AgentProbe(paths: paths, locator: await locate(), timing: timing).run(statuses)
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

    private func lacking(_ prerequisite: InstallPrerequisite?) async -> InstallPrerequisite? {
        guard let prerequisite else { return nil }
        let locator = await locate()
        guard let executable = locator.candidates(prerequisite.command).first else { return prerequisite }
        switch await capture(executable, ["--version"], locator: locator) {
        case .finished(_, let output): return AgentVersion(parsing: output).map { $0 >= prerequisite.minimum } == true ? nil : prerequisite
        case .timedOut: return nil
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
