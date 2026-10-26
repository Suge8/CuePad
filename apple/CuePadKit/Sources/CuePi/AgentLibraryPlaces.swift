#if os(macOS)
import CueStore
import Foundation

/// 技能与说明在这台 Mac 上的位置（2026-10 实测各家怎么读）：
/// - 技能：全局 `~/.agents/skills`、项目 `<文件夹>/.agents/skills`，Pi、Codex、OpenCode 原生读（递归、跟链接）；Claude Code 不读 `.agents`、
///   不递归，只读 `<它的目录>/skills/<名>` 与 `<文件夹>/.claude/skills/<名>`，所以逐个技能链过去（整个目录链不行：它往 `skills/synced` 写 claude.ai 同步的技能）。
/// - 旧目录：各家自己的技能目录与项目里的 `.claude`、`.pi`、`.codex`、`.opencode` 下的。
/// - 全局说明：`~/.agents/AGENTS.md`，Claude Code 的 `CLAUDE.md`、Codex、Pi 的 `AGENTS.md` 链到它；OpenCode 没有自己那份时读 Claude Code 的。
///   替换基础提示的两份（Pi 的 `SYSTEM.md`、Codex 配置里 `model_instructions_file` 指的）只作比对来源。
/// - 项目说明：`<文件夹>/AGENTS.md`；同层有 `CLAUDE.md`、`.claude/CLAUDE.md` 或 `CLAUDE.local.md` 时 Claude Code 不读它（2026-10 官方文档），
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

    /// Claude Code 在这一层读技能的目录（它不用就没有）。
    func claudeSkills(_ scope: LibraryScope) -> URL? {
        guard uses(.claudeCode) else { return nil }
        switch scope {
        case .global: return paths.home(of: .claudeCode).appending(path: "skills", directoryHint: .isDirectory)
        case .project(let id): return projects[id]?.appending(path: ".claude/skills", directoryHint: .isDirectory)
        }
    }

    /// 这一层的旧目录：哪家的、递不递归（Claude Code 只读一层）。全局的只列这台用着的几家。
    func oldSkills(_ scope: LibraryScope) -> [(directory: URL, agent: AgentKind, recursive: Bool)] {
        switch scope {
        case .global:
            installed.flatMap { kind -> [(URL, AgentKind, Bool)] in
                let home = paths.home(of: kind)
                let names = kind == .opencode ? ["skills", "skill"] : ["skills"]
                return names.map { (home.appending(path: $0, directoryHint: .isDirectory), kind, kind != .claudeCode) }
            }
        case .project(let id):
            projects[id].map { folder in
                [(".claude/skills", AgentKind.claudeCode), (".pi/skills", .pi), (".codex/skills", .codex), (".opencode/skills", .opencode), (".opencode/skill", .opencode)]
                    .map { (folder.appending(path: $0.0, directoryHint: .isDirectory), $0.1, $0.1 != .claudeCode) }
            } ?? []
        }
    }

    private func base(_ scope: LibraryScope) -> URL? {
        switch scope {
        case .global: paths.agentsDirectory
        case .project(let id): projects[id]
        }
    }

    // MARK: 说明

    var globalInstructions: URL { paths.agentsDirectory.appending(path: "AGENTS.md") }

    /// 这家自己的全局说明。
    func globalFile(_ kind: AgentKind) -> URL {
        paths.home(of: kind).appending(path: kind == .claudeCode ? "CLAUDE.md" : "AGENTS.md")
    }

    /// 链到全局说明的几家（OpenCode 不链：它没有自己那份时读 Claude Code 的）。
    var linkedKinds: [AgentKind] { installed.filter { $0 != .opencode } }

    var piSystem: URL { paths.home(of: .pi).appending(path: "SYSTEM.md") }
    var codexConfig: URL { paths.home(of: .codex).appending(path: "config.toml") }

    func projectInstructions(_ id: UUID) -> URL? { projects[id]?.appending(path: "AGENTS.md") }
    /// Claude Code 在项目里读的说明：有其中任一个它就不读 AGENTS.md。`local` 是个人的、不入库的那份，整理不碰。
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
