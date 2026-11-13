import CueStore
import SwiftUI

struct SkillSection: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let groups = SkillGroups(library, order: workspace.catalog?.projects.map(\.id) ?? [])
        let labeled = groups.global.count > 1 || groups.global.first?.name.isEmpty == false
        VStack(alignment: .leading, spacing: LibraryLayout.gap) {
            TidySlot(library: library, rules: false)
            ForEach(groups.global, id: \.name) { category in
                if labeled {
                    LibraryGroup(count: category.skills.count) {
                        Text(verbatim: category.name.isEmpty ? String(localized: "不在分类里") : category.name)
                    } content: {
                        rows(category.skills)
                    }
                } else {
                    VStack(spacing: 0) { rows(category.skills) }
                }
            }
            ForEach(groups.projects) { group in
                LibraryGroup(count: group.skills.count) {
                    HStack(spacing: Spacing.glyph) {
                        ProjectGlyph(project: workspace.catalog?.project(group.project), size: Self.glyph)
                        Text(verbatim: workspace.projectName(group.project))
                    }
                } content: {
                    rows(group.skills)
                }
            }
            if let note = library.selfManagedNote {
                Text(verbatim: note).font(Typography.meta).foregroundStyle(palette.ink3)
            }
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 13
    #else
    private static let glyph: CGFloat = 14
    #endif

    private func rows(_ skills: [LibrarySkill]) -> some View {
        VStack(spacing: 0) { ForEach(skills) { SkillRow(skill: $0, library: library) } }
    }
}

/// 几十上百个技能不逐个套卡：名字与一句说明排成清单，直接在桌面上（行底向两边让出，字与分组标题对齐，`RowStyle`）。
private struct SkillRow: View {
    let skill: LibrarySkill
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button { workspace.openLibrary(.skill(skill.path)) } label: { row }
            .buttonStyle(.row)
            #if os(macOS)
            .contextMenu {
                Button("在访达中显示", icon: .folder) { workspace.revealSkill(skill.path) }
            }
            #endif
    }

    private var row: some View {
        HStack(spacing: Spacing.group) {
            #if os(macOS)
            HStack(spacing: Spacing.tight) {
                name.frame(maxWidth: .infinity, alignment: .leading)
                mark
            }
            .frame(width: Self.nameWidth)
            description.frame(maxWidth: .infinity, alignment: .leading)
            #else
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.tight) { name.layoutPriority(1); mark }
                description
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
            UnseenMarks(agents: library.agents, unseen: skill.unseenBy)
        }
        .padding(.vertical, Self.vertical)
        .frame(minHeight: Self.height)
        .contentShape(.rect)
    }

    private var name: some View {
        Text(verbatim: skill.name).font(Self.nameFont).foregroundStyle(palette.ink).lineLimit(1)
    }

    private var description: some View {
        Text(verbatim: skill.description).font(Self.descriptionFont).foregroundStyle(palette.ink2).lineLimit(1)
    }

    @ViewBuilder private var mark: some View {
        Group {
            if skill.problem != nil {
                FailureMark().iconLabel("格式不对")
            } else if library.duplicate(of: skill.path) != nil {
                Image(.duplicate).foregroundStyle(palette.ink2).iconLabel("有同名的")
            }
        }
        .font(Self.markFont)
        #if os(macOS)
        .frame(width: Self.markWidth)
        #endif
    }

    private static let nameFont = Typography.body.weight(.medium)
    private static let descriptionFont = Typography.meta
    #if os(macOS)
    private static let markFont = Glyph.small
    private static let nameWidth: CGFloat = 220
    private static let markWidth: CGFloat = 16
    private static let vertical: CGFloat = 0
    private static let height: CGFloat = 36
    #else
    private static let markFont = Typography.meta
    private static let vertical = Spacing.item
    private static let height: CGFloat = 56
    #endif
}
