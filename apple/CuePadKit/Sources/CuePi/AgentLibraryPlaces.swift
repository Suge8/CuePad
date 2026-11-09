#if os(macOS)
import CueStore
import Foundation

/// 2026-10 实测各家怎么读：
/// - 技能：全局 `~/.agents/skills`、项目 `<文件夹>/.agents/skills`，Pi、Codex、OpenCode 原生读（递归、跟链接）；dsh 只读一层，Claude Code 不读，
///   读不到的逐个链到它们自己的技能目录（`SharedSkills`）。
/// - 全局规则：各家只原生读自己配置目录里那份（2026-11 用钉住的版本截请求实测；Claude Code 的是 `CLAUDE.md`，其余是 `AGENTS.md`），
///   没有哪家读与具体 Agent 无关的位置，所以共享的那份放在 `~/.config/agents/AGENTS.md`（agents.md 规范仓库第 91 号提案的位置，随 `XDG_CONFIG_HOME`），
///   各家那份都链到它。否决：`~/.agents/AGENTS.md`（只有 dsh 读，而 `~/.agents` 常是仓库，那份是它的项目规则）、`~/AGENTS.md` 与 `~/.config/AGENTS.md`
///   （在家目录、配置目录下干活的 Agent 往上找会当项目规则再读一遍，后者还常是 dotfiles 仓库）、借某一家的那份（卸掉那家就断）。
///   OpenCode v2 没有自己那份时不读 Claude Code 的（v1 读）。替换基础提示的两份（Pi 的 `SYSTEM.md`、Codex 配置里 `model_instructions_file` 指的）只作比对来源。
/// - 项目规则：`<文件夹>/AGENTS.md`；同层有 `CLAUDE.md`、`.claude/CLAUDE.md` 或 `CLAUDE.local.md` 时 Claude Code 不读它（2026-10 官方文档），
///   `CLAUDE.md` 链到 AGENTS.md 时经链接读到，同全局。
struct AgentLibraryPlaces: Sendable {
    let paths: AgentPaths
    let installed: [AgentKind]
    let projects: [UUID: URL]

    init(paths: AgentPaths, touches: (AgentKind) -> Bool, projects: [UUID: String]) {
        self.paths = paths
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
        case .project(let id):
            guard let file = projectInstructions(id) else { throw AgentLibraryError.noFolder }
            return file
        }
    }
}
#endif
