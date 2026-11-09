import CueStore
import SwiftUI

/// 规则（哪些该整理、谁读得到）在 `AgentLibrary`、`LibraryTidy` 与 Mac 端的扫描里，这里只把快照写成字。
extension Workspace {
    func fact(of tidy: LibraryTidy, in library: AgentLibrary) -> String {
        switch tidy.kind {
        case .stray(let moves): return String(localized: "\(moves.count) 个技能在旧目录里")
        case .unlinked(let agent, let skills): return String(localized: "\(skills.count) 个技能 \(agent.name) 读不到")
        case .empty(let directories): return String(localized: "\(directories.count) 个空文件夹")
        case .globalInstructions:
            let unseen = library.instruction(.global).map(library.unseen) ?? []
            let names = AgentKind.allCases.filter { tidy.writers.contains($0) || unseen.contains($0) }.map(\.name)
            return String(localized: "\(names.formatted(.list(type: .and))) 没链到全局规则")
        case .projectClaude(let project, _): return String(localized: "Claude Code 读不到「\(projectName(project))」的项目规则")
        case .duplicate(let name, _): return name
        }
    }

    func fileTitle(_ file: LibraryFile, in library: AgentLibrary?) -> String {
        switch file {
        case .skill(let path): library?.skill(at: path).map { scopeName($0.scope) } ?? ""
        case .instruction(let kind): instructionName(kind)
        }
    }

    func scopeName(_ scope: LibraryScope) -> String {
        switch scope {
        case .global: String(localized: "全局")
        case .project(let id): projectName(id)
        }
    }

    func projectName(_ id: UUID) -> String { catalog?.project(id)?.shownName ?? String(localized: "项目") }

    func copyName(_ copy: SkillEntry, among copies: [SkillEntry]) -> String {
        let scope = scopeName(copy.scope)
        guard copies.filter({ $0.scope == copy.scope }).count > 1 else { return scope }
        let parts = copy.path.split(separator: "/")
        guard let skills = parts.lastIndex(where: { $0 == "skills" || $0 == "skill" }), skills > 0 else { return scope }
        return Dotted(scope, String(parts[skills - 1])).visible
    }

    func replacementName(_ origin: InstructionSource.Origin) -> String {
        origin == .piSystem ? String(localized: "Pi 的系统提示") : String(localized: "Codex 的自定提示词")
    }
}

extension LibraryTidy {
    var icon: Icon {
        switch kind {
        case .stray: .folder
        case .unlinked, .globalInstructions, .projectClaude: .link
        case .empty: .unbindFolder
        case .duplicate: .duplicate
        }
    }
}

extension SelfManagedSkills {
    var title: String {
        agent == .claudeCode ? String(localized: "Claude Code 从 claude.ai 同步的 \(count) 个") : String(localized: "\(agent.name) 自带的 \(count) 个")
    }
}

nonisolated struct SkillGroups {
    struct Category {
        let name: String
        let skills: [LibrarySkill]
    }

    struct ProjectSkills: Identifiable {
        let project: UUID
        let skills: [LibrarySkill]
        var id: UUID { project }
    }

    let global: [Category]
    let projects: [ProjectSkills]

    init(_ library: AgentLibrary, order: [UUID]) {
        let global = library.skills(in: .global)
        let named = Dictionary(grouping: global.filter { !$0.group.isEmpty }, by: \.group).sorted { $0.key < $1.key }
        let loose = global.filter(\.group.isEmpty)
        self.global = named.map { Category(name: $0.key, skills: $0.value) } + (loose.isEmpty ? [] : [Category(name: "", skills: loose)])
        var byProject: [UUID: [LibrarySkill]] = [:]
        for skill in library.skills { if case .project(let id) = skill.scope { byProject[id, default: []].append(skill) } }
        let ranked = order.filter { byProject[$0] != nil } + byProject.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        projects = ranked.map { ProjectSkills(project: $0, skills: byProject[$0] ?? []) }
    }
}

/// Mac 悬停一个写"<那家> 读不到"，读屏整组念同一句。槽位定宽（这台装着几家就几格，`AgentLibrary.agents`），标志靠右排，各行的名字与说明不随它挪。
struct UnseenMarks: View {
    let agents: [AgentKind]
    let unseen: [AgentKind]
    @Environment(\.palette) private var palette

    private static let width: CGFloat = 18
    private static let mark: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            ForEach(agents.filter(unseen.contains), id: \.self) { kind in
                StruckBrandMark(mark: kind.mark, size: Self.mark).foregroundStyle(palette.ink3).frame(width: Self.width)
                    .help(String(localized: "\(kind.name) 读不到"))
            }
        }
        .frame(width: Self.width * CGFloat(agents.count), alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unseen.isEmpty ? "" : String(localized: "\(unseen.map(\.name).formatted(.list(type: .and))) 读不到"))
        .accessibilityHidden(unseen.isEmpty) // 合并：整行合并成一个元素，直接写就藏得住；readerHidden 的容器会把这句挡在合并外
    }
}
