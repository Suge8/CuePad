import CueStore
import SwiftUI

/// 技能与说明里给人看的写法（两端同一份）：要整理的一件写什么、一份说明下面那一行、技能分几组、比一比的各份叫什么。
/// 规则（哪些算要整理、谁读得到）在 `AgentLibrary`、`LibraryTidy` 与 Mac 端的扫描里，这里只把快照写成字。
extension Workspace {
    /// 要整理的那一件下面那一行：涉及哪些（名字、范围、哪几家），一行写得下的。
    func detail(of tidy: LibraryTidy, in library: AgentLibrary) -> String {
        switch tidy.kind {
        case .stray(let moves): return Self.names(moves.map(\.skill.name))
        case .unlinked(let skills):
            let global = skills.filter { $0.scope == .global }.map(\.name)
            let inProjects = skills.filter { $0.scope != .global }
            let projects = Set(inProjects.map(\.scope)).count
            if inProjects.isEmpty { return Self.names(global) }
            if global.isEmpty { return String(localized: "\(projects) 个项目里的 \(inProjects.count) 个") }
            return String(localized: "\(Self.names(global))，和 \(projects) 个项目里的 \(inProjects.count) 个")
        case .duplicate(_, let copies):
            return String(localized: "\(copies.map { scopeName($0.skill.scope) }.formatted(.list(type: .and))) 各一份")
        case .malformed(_, let problem): return problem.description
        case .empty(let directories): return Self.names(directories.map { ($0 as NSString).lastPathComponent })
        case .globalInstructions(let sources):
            let owners = AgentKind.allCases.filter(Set(sources.compactMap(\.origin.agent)).contains).map(\.name)
            return tidy.differs ? String(localized: "\(owners.formatted(.list(type: .and))) 各一份，内容不同") : String(localized: "内容一样，换成链接就行")
        case .projectClaude(let project, _):
            return String(localized: "\(projectName(project))：Claude Code 读的是它，不读 AGENTS.md")
        }
    }

    /// 全局，或项目名（项目在本端的目录里找不到时写"项目"）。
    func scopeName(_ scope: LibraryScope) -> String {
        switch scope {
        case .global: String(localized: "全局")
        case .project(let id): projectName(id)
        }
    }

    func projectName(_ id: UUID) -> String { catalog?.project(id)?.shownName ?? String(localized: "项目") }

    /// 比一比里一份说明叫什么：共读的那份（全局说明、项目的 AGENTS.md）、哪家自己的那份、Pi 的系统提示、Codex 的自定提示词。
    func sourceName(_ origin: InstructionSource.Origin, project: UUID?) -> String {
        switch origin {
        case .shared: project == nil ? String(localized: "全局说明") : "AGENTS.md"
        case .agent(let kind): kind.name
        case .piSystem: String(localized: "Pi 的系统提示")
        case .codexPrompt: String(localized: "Codex 的自定提示词")
        }
    }

    /// 一份说明名字下面那一行：有没有这个文件、谁读它、谁链到它。
    func line(of instruction: LibraryInstruction, readers columns: [AgentKind]) -> String {
        guard instruction.text != nil else {
            return instruction.kind == .global ? String(localized: "还没有") : String(localized: "还没有 AGENTS.md")
        }
        switch instruction.kind {
        case .global:
            let readers = instruction.readers.map(\.name)
            return readers.isEmpty ? String(localized: "还没有一家读它") : String(localized: "\(Self.names(readers, limit: readers.count)) 都读这一份")
        case .piSystem:
            return String(localized: "换掉了 Pi 自带的系统提示")
        case .project:
            let linked = instruction.links.contains { ($0 as NSString).lastPathComponent == "CLAUDE.md" }
            let blocked = columns.contains(.claudeCode) && !instruction.readers.contains(.claudeCode)
            return Dotted("AGENTS.md", linked ? String(localized: "CLAUDE.md 链到它") : nil, blocked ? String(localized: "Claude Code 读的是另一份") : nil).visible
        }
    }

    /// 几个名字：三个以内都写（"a、b 和 c"），再多写前两个"等 N 个"。
    static func names(_ names: [String], limit: Int = 3) -> String {
        if names.count <= limit { return names.formatted(.list(type: .and)) }
        return String(localized: "\(names.prefix(2).formatted(.list(type: .and))) 等 \(names.count) 个")
    }
}

extension AgentLibrary {
    /// 技能右端的几列：那台报的能用的几家（`MacAgents`），加上快照里提到的几家（谁看不见哪个技能、谁读哪份说明）——
    /// 装了还没登录的那家也会看不见技能，它的空圈得有一列放。顺序同 `AgentKind`。
    func columns(reported: [AgentKind]) -> [AgentKind] {
        let named = Set(reported + skills.flatMap(\.unseenBy) + instructions.flatMap(\.readers))
        return AgentKind.allCases.filter(named.contains)
    }
}

extension SelfManagedSkills {
    /// "Claude Code 从 claude.ai 同步的 13 个"、"Codex 自带的 5 个"。
    var title: String {
        agent == .claudeCode ? String(localized: "Claude Code 从 claude.ai 同步的 \(count) 个") : String(localized: "\(agent.name) 自带的 \(count) 个")
    }
}

extension LibraryTidy {
    /// 这一件行首的图：在哪（文件夹）、谁看不见（那家的标志）、撞名、格式不对（出错）、空目录、说明。
    var icon: Icon {
        switch kind {
        case .stray: .folder
        case .unlinked: .link
        case .duplicate: .conflict
        case .malformed: .failure
        case .empty: .unbindFolder
        case .globalInstructions, .projectClaude: .instruction
        }
    }

    /// 那一件做不做得了：格式不对要在 Mac 上打开自己改，手机上只写出哪里不对。
    func actionable(onMac: Bool) -> Bool {
        if case .malformed = kind { onMac } else { true }
    }
}

/// 技能清单的几组：全局一组（按分类排，"不在分类里"的最后），各项目各一组（按项目目录的先后），再是各家自己管的（只写个数）。
nonisolated struct SkillGroups: Equatable {
    struct Category: Equatable, Identifiable {
        let name: String
        let skills: [LibrarySkill]
        var id: String { name }
    }

    struct ProjectSkills: Equatable, Identifiable {
        let project: UUID
        let skills: [LibrarySkill]
        var id: UUID { project }
    }

    let global: [Category]
    let projects: [ProjectSkills]
    let total: Int

    init(_ library: AgentLibrary, order: [UUID]) {
        let global = library.skills(in: .global)
        let named = Dictionary(grouping: global.filter { !$0.group.isEmpty }, by: \.group).sorted { $0.key < $1.key }
        let loose = global.filter(\.group.isEmpty)
        self.global = named.map { Category(name: $0.key, skills: $0.value) } + (loose.isEmpty ? [] : [Category(name: "", skills: loose)])
        var byProject: [UUID: [LibrarySkill]] = [:]
        for skill in library.skills { if case .project(let id) = skill.scope { byProject[id, default: []].append(skill) } }
        let ranked = order.filter { byProject[$0] != nil } + byProject.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        projects = ranked.map { ProjectSkills(project: $0, skills: byProject[$0] ?? []) }
        total = library.skills.count
    }
}

/// 一行技能右端的几列：这台 Mac 接入的每一家一列（顺序同 `AgentKind`），看得见是那家的标志，看不见留一个空圈。
/// 同一列上下对齐：哪家漏了哪个，一眼顺着列看出来。表头那一行（`header`）同列宽，标志是次一级墨色。
struct AgentColumns: View {
    let columns: [AgentKind]
    var unseen: [AgentKind] = []
    var header = false
    @Environment(\.palette) private var palette

    static let width: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { kind in
                Group {
                    if unseen.contains(kind) {
                        Circle().strokeBorder(palette.track, lineWidth: 1.2).frame(width: 11, height: 11)
                    } else {
                        kind.mark.image.font(.system(size: header ? 12 : 11)).foregroundStyle(header ? palette.ink2 : palette.ink3)
                    }
                }
                .frame(width: Self.width)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        if header { return columns.map(\.name).formatted(.list(type: .and)) }
        let missing = columns.filter(unseen.contains).map(\.name)
        return missing.isEmpty ? String(localized: "各家都看得见") : String(localized: "\(missing.formatted(.list(type: .and))) 看不见")
    }
}
