#if os(macOS)
import CueStore
import Foundation

/// 2026-10 实测各家怎么读：
/// - 技能：全局 `~/.agents/skills`、项目 `<文件夹>/.agents/skills`，Pi、Codex、OpenCode 原生读（递归、跟链接）；dsh 只读一层，Claude Code 不读，
///   读不到的逐个链到它们自己的技能目录（`SharedSkills`）。
/// - 全局规则：各家只原生读自己配置目录里那几份（2026-11 用钉住的版本截请求实测，每家读哪几份写在它的 `+Facts`），
///   没有哪家读与具体 Agent 无关的位置，所以共享的那份放在 `~/.config/agents/AGENTS.md`（agents.md 规范仓库第 91 号提案的位置，随 `XDG_CONFIG_HOME`），
///   各家链到它的位置是 `AgentFacts.instructionsFile`；它们原生读的几份（`globalReads`）里别的那几份，整理时并进共享那份、进废纸篓（不然链接被挡住或白读两遍）。
///   dsh 另原生读 `~/.agents/AGENTS.md`：不列、不碰。对其余五家那是 `~/.agents` 那个目录（常是仓库）的项目规则，当全局规则列会误导；
///   改 `DSH_AGENTS_HOME` 能让 dsh 不读它，但同一个变量也定它读哪里的共享技能，所以不改。否决：`~/.agents/AGENTS.md`（只有 dsh 读，而 `~/.agents` 常是仓库，那份是它的项目规则）、`~/AGENTS.md` 与 `~/.config/AGENTS.md`
///   （在家目录、配置目录下干活的 Agent 往上找会当项目规则再读一遍，后者还常是 dotfiles 仓库）、借某一家的那份（卸掉那家就断）。
///   Claude Code 配置目录里的 `AGENTS.md` 也算全局规则、整理时并进来：Claude Code 是在 ~ 这一层当项目规则读到它，但项目都在 ~ 下，
///   凡在 ~ 下的项目它都读到；Grok 在哪都读。所以它实际是全局生效的（2.1.318 实测，`globalFiles`）。
///   OpenCode v2 没有自己那份时不读 Claude Code 的（v1 读）。替换基础提示的两份（Pi 的 `SYSTEM.md`、Codex 配置里 `model_instructions_file` 指的）只作比对来源。
/// - 项目规则：`<文件夹>/AGENTS.md`；同层有 `CLAUDE.md`、`.claude/CLAUDE.md` 或 `CLAUDE.local.md` 时 Claude Code 不读它（2026-10 官方文档），
///   往上哪一层有这几份之一时也不读（2.1.318 实测，`claudeAbove`；`~/.claude/CLAUDE.md` 就是 ~ 这一层的）；`CLAUDE.md` 链到 AGENTS.md 时经链接读到。
struct AgentLibraryPlaces: Sendable {
    let paths: AgentPaths
    let installed: [AgentKind]
    let projects: [UUID: URL]
    let grokClaude: URL?

    init(paths: AgentPaths, touches: (AgentKind) -> Bool, grokClaude: URL?, projects: [UUID: String]) {
        self.paths = paths
        self.grokClaude = grokClaude
        installed = AgentKind.allCases.filter { touches($0) && FileManager.default.fileExists(atPath: paths.home(of: $0).path) }
        self.projects = projects.mapValues { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    func uses(_ kind: AgentKind) -> Bool { installed.contains(kind) }

    var scopes: [LibraryScope] {
        [.global] + projects.sorted { $0.value.path < $1.value.path }.map { .project($0.key) }
    }

    func skills(_ scope: LibraryScope) -> URL? {
        base(scope).map { $0.appending(path: scope == .global ? "skills" : ".agents/skills", directoryHint: .isDirectory) }
    }

    func links(_ name: String, group: String, in scope: LibraryScope) -> [(agent: AgentKind, link: URL)] {
        installed.filter { !$0.facts.sharedSkills.reaches(group: group) }.compactMap { kind in link(name, for: kind, in: scope).map { (kind, $0) } }
    }

    func link(_ name: String, for kind: AgentKind, in scope: LibraryScope) -> URL? {
        let parent = switch scope {
        case .global: paths.home(of: kind)
        case .project(let id): projects[id]?.appending(path: kind.facts.projectFolder, directoryHint: .isDirectory)
        }
        return parent?.appending(path: "skills/\(name)", directoryHint: .isDirectory)
    }

    func oldSkills(_ scope: LibraryScope) -> [(directory: URL, agent: AgentKind, recursive: Bool)] {
        switch scope {
        case .global:
            installed.flatMap { kind in skillFolders(of: kind, in: paths.home(of: kind)) }
        case .project(let id):
            projects[id].map { folder in
                AgentKind.allCases.flatMap { skillFolders(of: $0, in: folder.appending(path: $0.facts.projectFolder, directoryHint: .isDirectory)) }
            } ?? []
        }
    }

    private func skillFolders(of kind: AgentKind, in parent: URL) -> [(directory: URL, agent: AgentKind, recursive: Bool)] {
        kind.facts.skillFolders.map { (parent.appending(path: $0, directoryHint: .isDirectory), kind, kind.facts.sharedSkills == .recursive) }
    }

    private func base(_ scope: LibraryScope) -> URL? {
        switch scope {
        case .global: paths.agentsDirectory
        case .project(let id): projects[id]
        }
    }

    var globalInstructions: URL { paths.agentsConfigDirectory.appending(path: "AGENTS.md") }

    func globalFile(_ kind: AgentKind) -> URL {
        paths.home(of: kind).appending(path: kind.facts.instructionsFile)
    }

    /// 这一家此刻原生读的全局规则（在的，含链接）。
    func globalReads(_ kind: AgentKind) -> [URL] {
        let present = kind.facts.globalReads.map { paths.home(of: kind).appending(path: $0) }.filter(LibraryFileReading.exists)
        return kind.facts.readsFirstOnly ? Array(present.prefix(1)) : present
    }

    /// 一家原生读的一份全局规则（链到共享那份的链接位置除外）。`retires` 的整理时并进共享那份、进废纸篓：
    /// 留着它们，链接被挡住（覆盖文件、Pi 只有 CLAUDE.md 时那份）、或各家在共享那份之外还读一份旧的。
    /// 不 `retires` 的是另加的、不挡也不重复的（Claude Code `rules/` 下自己写的那几份）：照列，整理不碰。
    struct GlobalFile {
        let owner: AgentKind
        /// 页面上的名字、文件页认它的键（`LibraryInstruction.Kind.agent`）：配置目录里的相对路径，Grok 读的 ~/.claude 那几份写成 `~/.claude/…`
        let name: String
        let url: URL
        let readers: [AgentKind]
        let retires: Bool
    }

    /// 页面、比对、整理、文件页只认这一份清单。
    var globalFiles: [GlobalFile] {
        let shared = globalInstructions
        var found: [GlobalFile] = []
        let claudeHome = paths.home(of: .claudeCode)
        let grokSeesClaude = uses(.grok) && uses(.claudeCode) && grokClaude?.standardizedFileURL == claudeHome.standardizedFileURL
        func add(_ owner: AgentKind, _ name: String, _ url: URL, readers: [AgentKind], retires: Bool) {
            guard !RelativeLink.points(url, to: shared) || url != globalFile(owner) else { return }
            found.append(GlobalFile(owner: owner, name: name, url: url, readers: readers, retires: retires))
        }
        for kind in installed {
            let also: [AgentKind] = kind == .claudeCode && grokSeesClaude ? [.grok] : []
            for url in globalReads(kind) {
                add(kind, String(url.path.dropFirst(paths.home(of: kind).path.count + 1)), url, readers: [kind] + also, retires: true)
            }
        }
        if uses(.claudeCode) {
            let also: [AgentKind] = grokSeesClaude ? [.grok] : []
            // 配置目录里的 AGENTS.md：在 ~ 下干活、项目里一路没有 CLAUDE.md 时它当 ~ 这一层的项目规则读（2.1.318 实测），
            // ~ 下的项目就都读到；Grok 在哪都读。共享那份之外再读一份旧的，所以并进去
            let agents = claudeHome.appending(path: "AGENTS.md")
            if LibraryFileReading.exists(agents) { add(.claudeCode, "AGENTS.md", agents, readers: [.claudeCode] + also, retires: true) }
            for url in Self.markdown(in: claudeHome.appending(path: "rules", directoryHint: .isDirectory)) where url != globalFile(.claudeCode) {
                add(.claudeCode, String(url.path.dropFirst(claudeHome.path.count + 1)), url, readers: [.claudeCode] + also, retires: false)
            }
        }
        if uses(.grok), !grokSeesClaude, let directory = grokClaude {
            for name in ["CLAUDE.md", "AGENTS.md"] where LibraryFileReading.exists(directory.appending(path: name)) {
                add(.grok, "~/.claude/" + name, directory.appending(path: name), readers: [.grok], retires: true)
            }
            for url in Self.markdown(in: directory.appending(path: "rules", directoryHint: .isDirectory)) where !RelativeLink.points(url, to: shared) {
                add(.grok, "~/.claude/" + url.path.dropFirst(directory.path.count + 1), url, readers: [.grok], retires: false)
            }
        }
        return found
    }

    /// `rules/` 下（含子目录）每一份 .md，按路径排。
    private static func markdown(in directory: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "md" && LibraryFileReading.exists($0) }
            .map { directory.appending(path: String($0.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))) }
            .sorted { $0.path < $1.path }
    }

    /// 这个目录往上（不含它自己）有 Claude Code 当作 CLAUDE.md 的文件：它就不读这个目录的 AGENTS.md（2.1.318 实测）。
    func claudeAbove(_ folder: URL) -> [URL] {
        var found: [URL] = [], directory = folder.standardizedFileURL.deletingLastPathComponent()
        while true {
            found += ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"].map { directory.appending(path: $0) }.filter(LibraryFileReading.exists)
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return found }
            directory = parent
        }
    }

    var piSystem: URL { paths.home(of: .pi).appending(path: "SYSTEM.md") }
    var codexConfig: URL { paths.home(of: .codex).appending(path: "config.toml") }

    func projectInstructions(_ id: UUID) -> URL? { projects[id]?.appending(path: "AGENTS.md") }
    /// `local` 是个人的、不入库的那份，整理不碰。
    func projectClaude(_ id: UUID) -> (main: URL, nested: URL, local: URL)? {
        projects[id].map { ($0.appending(path: "CLAUDE.md"), $0.appending(path: ".claude/CLAUDE.md"), $0.appending(path: "CLAUDE.local.md")) }
    }

    func file(_ kind: LibraryInstruction.Kind) throws -> URL {
        switch kind {
        case .global: return globalInstructions
        case .piSystem: return piSystem
        case .agent(let agent, let name):
            guard let file = globalFiles.first(where: { $0.owner == agent && $0.name == name }) else { throw AgentLibraryError.gone }
            return file.url
        case .project(let id):
            guard let file = projectInstructions(id) else { throw AgentLibraryError.noFolder }
            return file
        }
    }
}
#endif
