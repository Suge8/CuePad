#if os(macOS)
import CueStore
import Foundation

/// 技能与规则在这台 Mac 上的位置（2026-10 实测各家怎么读）：
/// - 技能：全局 `~/.agents/skills`、项目 `<文件夹>/.agents/skills`，Pi、Codex、OpenCode 原生读（递归、跟链接）；dsh 只读一层，Claude Code 不读，
///   读不到的逐个链到它们自己的技能目录（`SharedSkills`）。
/// - 旧目录：各家自己的技能目录与项目里的 `.claude`、`.pi`、`.codex`、`.opencode` 下的。
/// - 全局规则：`~/.agents/AGENTS.md`，Claude Code 的 `CLAUDE.md`、Codex、Pi 的 `AGENTS.md` 链到它；OpenCode 没有自己那份时读 Claude Code 的。
///   替换基础提示的两份（Pi 的 `SYSTEM.md`、Codex 配置里 `model_instructions_file` 指的）只作比对来源。
/// - 项目规则：`<文件夹>/AGENTS.md`；同层有 `CLAUDE.md`、`.claude/CLAUDE.md` 或 `CLAUDE.local.md` 时 Claude Code 不读它（2026-10 官方文档），
///   `CLAUDE.md` 链到 AGENTS.md 时经链接读到，同全局。
/// 碰不得的那家（隔离运行而它的目录是真实位置，`AgentIntegration.touches`）当作这台没有它。
struct AgentLibraryPlaces: Sendable {
    let paths: AgentPaths
    /// 这台用着的几家（配置目录在、碰得了），按 `AgentKind` 的顺序
    let installed: [AgentKind]
    /// 这台绑了文件夹的项目
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

    /// 这一层的 `.agents/skills`。
    func skills(_ scope: LibraryScope) -> URL? {
        base(scope).map { $0.appending(path: scope == .global ? "skills" : ".agents/skills", directoryHint: .isDirectory) }
    }

    /// 这一层 `group` 分类里叫 `name` 的技能要链到的位置：这台用着、读不到它的几家，各在自己读技能的目录里（`SharedSkills`）。
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

    /// 这一层的旧目录：哪家的、递不递归（同它读 `.agents` 的深度）。全局的只列这台用着的几家。
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

    // MARK: 规则

    var globalInstructions: URL { paths.agentsDirectory.appending(path: "AGENTS.md") }

    /// 这家自己的全局规则。
    func globalFile(_ kind: AgentKind) -> URL {
        paths.home(of: kind).appending(path: kind.facts.instructionsFile)
    }

    /// 链到全局规则的几家（`AgentFacts.linksGlobalInstructions`）。
    var linkedKinds: [AgentKind] { installed.filter(\.facts.linksGlobalInstructions) }

    var piSystem: URL { paths.home(of: .pi).appending(path: "SYSTEM.md") }
    var codexConfig: URL { paths.home(of: .codex).appending(path: "config.toml") }

    func projectInstructions(_ id: UUID) -> URL? { projects[id]?.appending(path: "AGENTS.md") }
    /// Claude Code 在项目里读的规则：有其中任一个它就不读 AGENTS.md。`local` 是个人的、不入库的那份，整理不碰。
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
