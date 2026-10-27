import CueStore
import SwiftUI

/// 技能与规则里给人看的写法（两端同一份）：一键整理那块纸上的几条事实、去重的几份叫什么、技能分几组、读不到的那几家怎么画。
/// 规则（哪些该整理、谁读得到）在 `AgentLibrary`、`LibraryTidy` 与 Mac 端的扫描里，这里只把快照写成字。
extension Workspace {
    /// 一键整理那块纸上的一条：结果的事实（多少个、谁读不到），不写要做什么。
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

    /// 文件页页顶写的那一份：技能写它在哪（全局或项目名，名字在下面的名字框里，不重复），规则写它的名字。
    func fileTitle(_ file: LibraryFile, in library: AgentLibrary?) -> String {
        switch file {
        case .skill(let path): library?.skill(at: path).map { scopeName($0.scope) } ?? ""
        case .instruction(let kind): instructionName(kind)
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

    /// 去重时一份叫什么：范围名；同一范围有几份时带上它所在的目录（旧目录里的，如 `.codex`）。
    func copyName(_ copy: SkillEntry, among copies: [SkillEntry]) -> String {
        let scope = scopeName(copy.scope)
        guard copies.filter({ $0.scope == copy.scope }).count > 1 else { return scope }
        let parts = copy.path.split(separator: "/")
        guard let skills = parts.lastIndex(where: { $0 == "skills" || $0 == "skill" }), skills > 0 else { return scope }
        return Dotted(scope, String(parts[skills - 1])).visible
    }

    /// 替换基础提示的那两份叫什么（合并时可选一并撤掉）。
    func replacementName(_ origin: InstructionSource.Origin) -> String {
        origin == .piSystem ? String(localized: "Pi 的系统提示") : String(localized: "Codex 的自定提示词")
    }
}

extension LibraryTidy {
    /// 一键整理那块纸上这一条行首的图。
    var icon: Icon {
        switch kind {
        case .stray: .folder
        case .unlinked, .globalInstructions, .projectClaude: .link
        case .empty: .unbindFolder
        case .duplicate: .conflict
        }
    }
}

extension SelfManagedSkills {
    /// "Claude Code 从 claude.ai 同步的 13 个"、"Codex 自带的 5 个"。
    var title: String {
        agent == .claudeCode ? String(localized: "Claude Code 从 claude.ai 同步的 \(count) 个") : String(localized: "\(agent.name) 自带的 \(count) 个")
    }
}

/// 技能清单的几组：全局一组（按分类排，"不在分类里"的最后），各项目各一组（按项目目录的先后）。
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

/// 一行右端读不到这一份的那几家：只画那几家的标志（淡墨），全读得到什么都不画。槽位定宽（这台装着几家就几格，`AgentLibrary.agents`），
/// 标志靠右排，各行的名字与说明不随它挪。
struct UnseenMarks: View {
    let agents: [AgentKind]
    let unseen: [AgentKind]
    @Environment(\.palette) private var palette

    static let width: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            ForEach(agents.filter(unseen.contains), id: \.self) { kind in
                kind.mark.image.font(.system(size: 11)).foregroundStyle(palette.ink3).opacity(0.7).frame(width: Self.width)
            }
        }
        .frame(width: Self.width * CGFloat(agents.count), alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unseen.isEmpty ? "" : String(localized: "\(unseen.map(\.name).formatted(.list(type: .and))) 读不到"))
        .accessibilityHidden(unseen.isEmpty)
    }
}
