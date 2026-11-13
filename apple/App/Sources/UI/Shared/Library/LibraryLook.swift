import CueStore
import SwiftUI

/// 规则（哪些该整理、谁读得到）在 `AgentLibrary`、`LibraryTidy` 与 Mac 端的扫描里，这里只把快照写成字。
extension Workspace {
    func fact(of tidy: LibraryTidy, in library: AgentLibrary) -> TidyFact {
        switch tidy.kind {
        case .stray(let moves):
            return TidyFact(
                problem: String(localized: "\(moves.count) 个技能不在共用目录里"),
                plan: String(localized: "搬进共用的 .agents/skills：\(Self.listed(moves.map(\.skill.name)))"))
        case .unlinked(let agent, let skills):
            return TidyFact(
                problem: String(localized: "\(skills.count) 个技能 \(agent.name) 读不到"),
                plan: String(localized: "在它的技能目录里建链接：\(Self.listed(skills.map(\.name)))"))
        case .empty(let directories):
            return TidyFact(
                problem: String(localized: "\(directories.count) 个空文件夹"),
                plan: String(localized: "移到废纸篓：\(Self.listed(directories.map(library.shown)))"))
        case .globalInstructions:
            guard let global = library.instruction(.global), global.hash != nil else {
                return TidyFact(
                    problem: String(localized: "还没有全局规则"),
                    plan: String(localized: "拿 \(tidy.writers.map(\.name).formatted(.list(type: .and))) 那份当全局规则，各家都链到它"))
            }
            let unseen = library.unseen(global)
            let names = AgentKind.allCases.filter { tidy.writers.contains($0) || unseen.contains($0) }.map(\.name)
            return TidyFact(
                problem: String(localized: "\(names.formatted(.list(type: .and))) 还没读全局规则"),
                plan: tidy.writers.isEmpty
                    ? String(localized: "在它的配置目录里建一个指向全局规则的链接")
                    : String(localized: "自己那份内容相同，换成指向全局规则的链接"))
        case .projectClaude(let project, _):
            return TidyFact(
                problem: String(localized: "Claude Code 读不到「\(projectName(project))」的项目规则"),
                plan: String(localized: "在项目里建一个指向 AGENTS.md 的 CLAUDE.md"))
        case .duplicate(let name, _):
            return TidyFact(problem: name, plan: "")
        }
    }

    /// 前三个写出来，其余只写个数。
    private static func listed(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: String(localized: "、"))
        return names.count > 3 ? String(localized: "\(shown) 等 \(names.count) 个") : shown
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

/// 该整理的一件写成两句：哪里不对、一键整理会对它做什么。
struct TidyFact: Equatable {
    let problem: String
    let plan: String
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

/// 装着的每一家一格：在读的画标志，读不到的划掉（同 `UnseenMarks`）。读屏念卡里的字。
struct ReaderMarks: View {
    let agents: [AgentKind]
    let reading: [AgentKind]
    @Environment(\.palette) private var palette

    private static let mark: CGFloat = 13

    var body: some View {
        HStack(spacing: Spacing.glyph) {
            ForEach(agents, id: \.self) { kind in
                if reading.contains(kind) {
                    kind.mark.image.font(.system(size: Self.mark)).foregroundStyle(palette.ink2).help(String(localized: "\(kind.name) 在读"))
                } else {
                    StruckBrandMark(mark: kind.mark, size: Self.mark).foregroundStyle(palette.ink3).help(String(localized: "\(kind.name) 读不到"))
                }
            }
        }
        .accessibilityHidden(true) // 合并：整张卡合并成一个元素，谁在读、谁另写了一份都在卡里的字上
    }
}
