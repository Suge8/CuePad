import CueStore
import SwiftUI

/// 技能：全局的一张纸按分类分组（分类名是纸里的一行淡字；只有一组且不在分类里时不写），各项目一张纸、纸上头写项目（图形与名字），
/// 最后各家自己管的只写个数（CuePad 不碰它们）。组名都与行首的字对齐。
/// 点一行在 CuePad 里打开它的文件页（Mac 的"在访达中显示"在右键菜单里）。
struct SkillSection: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let groups = SkillGroups(library, order: workspace.catalog?.projects.map(\.id) ?? [])
        VStack(alignment: .leading, spacing: LibraryLayout.gap) {
            TidySlot(library: library, rules: false)
            if !groups.global.isEmpty {
                let labeled = groups.global.count > 1 || groups.global.first?.name.isEmpty == false
                skills(groups.global.flatMap { category in (labeled ? [SkillLine.category(category.name)] : []) + category.skills.map(SkillLine.skill) })
            }
            ForEach(groups.projects) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProjectGlyph(project: workspace.catalog?.project(group.project), size: Self.glyph)
                        Text(verbatim: workspace.projectName(group.project))
                    }
                    .font(Typography.label).foregroundStyle(palette.ink2)
                    .padding(.horizontal, LibraryLayout.inset)
                    .accessibilityAddTraits(.isHeader)
                    skills(group.skills.map(SkillLine.skill))
                }
                .padding(.top, 8)
            }
            if !library.selfManaged.isEmpty {
                LibraryPaper {
                    ForEach(library.selfManaged, id: \.agent) { managed in
                        LibraryRow(title: managed.title) {
                            managed.agent.mark.image.foregroundStyle(palette.ink2)
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 12
    #else
    private static let glyph: CGFloat = 13
    #endif

    private func skills(_ lines: [SkillLine]) -> some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                switch line {
                case .category(let name):
                    Text(verbatim: name.isEmpty ? String(localized: "不在分类里") : name)
                        .font(Typography.label).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LibraryLayout.inset).padding(.top, 10).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                case .skill(let skill): SkillRow(skill: skill, library: library)
                }
            }
        }
        .padding(.vertical, 4)
        .paper(cornerRadius: LibraryLayout.radius)
        .rowContainer(.rect(cornerRadius: LibraryLayout.radius))
    }
}

private enum SkillLine: Identifiable {
    case category(String)
    case skill(LibrarySkill)

    var id: String {
        switch self {
        case .category(let name): "category/" + name
        case .skill(let skill): skill.id
        }
    }
}

/// 一个技能：名字（后面定位置一格：格式不对是出错的记号，同名的是两份的记号）、说明、行末读不到它的那几家。
/// Mac 一行排开；手机两行，名字一行、说明一行。
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
        HStack(spacing: 12) {
            #if os(macOS)
            HStack(spacing: 4) {
                name.frame(maxWidth: .infinity, alignment: .leading)
                mark
            }
            .frame(width: Self.nameWidth)
            description.frame(maxWidth: .infinity, alignment: .leading)
            #else
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { name.layoutPriority(1); mark }
                description
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
            UnseenMarks(agents: library.agents, unseen: skill.unseenBy)
        }
        .padding(.horizontal, LibraryLayout.inset)
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

    /// 名字后那一格：格式不对、同名，都不是时空着（Mac 上占着位置）。
    @ViewBuilder private var mark: some View {
        Group {
            if skill.problem != nil {
                FailureMark().accessibilityLabel(String(localized: "格式不对"))
            } else if library.duplicate(of: skill.path) != nil {
                Image(.duplicate).foregroundStyle(palette.ink2).accessibilityLabel(String(localized: "有同名的"))
            }
        }
        .font(Self.markFont)
        #if os(macOS)
        .frame(width: Self.markWidth)
        #endif
    }

    #if os(macOS)
    private static let nameFont = Typography.body.weight(.medium)
    private static let descriptionFont = Typography.meta
    private static let markFont = Font.system(size: 11)
    private static let nameWidth: CGFloat = 188
    private static let markWidth: CGFloat = 16
    private static let vertical: CGFloat = 0
    private static let height: CGFloat = 36
    #else
    private static let nameFont = Font.body.weight(.medium)
    private static let descriptionFont = Font.footnote
    private static let markFont = Font.footnote
    private static let vertical: CGFloat = 8
    private static let height: CGFloat = 56
    #endif
}
