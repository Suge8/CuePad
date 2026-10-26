import CueStore
import SwiftUI

/// 技能与说明页的三组（Mac 的页与手机的页同一份，`LibraryPage`、`LibraryScreen` 只管怎么摆）：
/// 要整理（只在有问题时出现，每件一句事实一个动作，"全部整理"做不要你挑的那几件）、说明（全局一行，Pi 的系统提示有才列，再是绑了文件夹的各项目）、
/// 技能（全局按分类、各项目各一组，每行右端各家一列，再是各家自己管的个数）。整理不弹确认：做完的提示带撤销（`Workspace.tidy`）。
/// 改动的写入都在那台 Mac 上：手机上的动作发往 Mac（按钮带纸飞机），快照随它写回同步来。

/// 一组的标题（带个数的把个数作为次一级的字嵌在整句里，英文才排得对：Skills 15）、右边的东西（"全部整理"、各家的列头）。
struct LibraryHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            title.font(Self.font).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: ControlMetrics.compactHeight)
        .padding(.horizontal, 4)
    }

    /// 组名后面次一级的个数（嵌进组名那一句里）。
    static func count(_ count: Int, palette: Palette) -> Text {
        Text("\(count)").font(countFont).foregroundStyle(palette.ink3)
    }

    #if os(macOS)
    private static var font: Font { Typography.sectionTitle }
    private static var countFont: Font { Typography.sectionCount }
    #else
    private static var font: Font { .headline }
    private static var countFont: Font { .footnote.monospacedDigit() }
    #endif
}

extension LibraryHeader where Trailing == EmptyView {
    init(title: Text) { self.init(title: title) { EmptyView() } }
}

/// 一组行的纸：行与行之间一线发丝（同设置的分组），手机上行铺满纸宽、首尾的圆角跟着纸（`rowContainer`）。
struct LibraryPaper<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    row
                    if row.id != rows.last?.id { Divider().padding(.leading, Self.inset + LibraryRowMetrics.icon + LibraryRowMetrics.gap) }
                }
            }
        }
        .padding(.vertical, Self.vertical)
        .paper(radius: Self.radius)
        .rowContainer(.rect(cornerRadius: Self.radius, style: .continuous), flush: Self.flush)
    }

    #if os(macOS)
    static var radius: CGFloat { 12 }
    static var inset: CGFloat { 16 }
    private static var vertical: CGFloat { 4 }
    private static var flush: Bool { false }
    #else
    static var radius: CGFloat { 22 }
    static var inset: CGFloat { 16 }
    private static var vertical: CGFloat { 0 }
    private static var flush: Bool { true }
    #endif
}

enum LibraryRowMetrics {
    #if os(macOS)
    static let icon: CGFloat = 18
    static let gap: CGFloat = 12
    static let height: CGFloat = 48
    #else
    static let icon: CGFloat = 22
    static let gap: CGFloat = 12
    static let height: CGFloat = 58
    #endif
}

/// 一行：图标一列、名字与下面一行、右边的东西。
struct LibraryRow<Icon: View, Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: LibraryRowMetrics.gap) {
            icon.frame(width: LibraryRowMetrics.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(Self.titleFont).foregroundStyle(palette.ink).lineLimit(Self.lines)
                if let detail { Text(verbatim: detail).font(Self.detailFont).foregroundStyle(palette.ink2).lineLimit(Self.lines) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, LibraryPaper<EmptyView>.inset)
        .padding(.vertical, Self.vertical)
        .frame(minHeight: LibraryRowMetrics.height)
        .contentShape(.rect)
    }

    private static var vertical: CGFloat { 8 }

    /// 一件事的那句写不下一行就折成两行，不截掉（手机窄、英文长）
    private static var lines: Int { 2 }

    #if os(macOS)
    private static var titleFont: Font { Typography.body.weight(.medium) }
    private static var detailFont: Font { Typography.meta }
    #else
    private static var titleFont: Font { .body }
    private static var detailFont: Font { .footnote }
    #endif
}

/// 要整理：标题写几件、"全部整理"（有不要你挑的才有）；每件一行，按钮是它的动作（`LibraryTidy.action`）。
/// 比一比打开比一比；格式不对在 Mac 上用默认的编辑器打开它的 SKILL.md；其余就地整理这一件。点下去那一件转圈，做完由提示说结果。
struct TidySection: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var working: Set<String> = []

    private static let all = "*"

    var body: some View {
        let orders = library.automaticOrders
        VStack(alignment: .leading, spacing: 10) {
            LibraryHeader(title: Text("\(library.tidies.count) 件要整理")) {
                if !orders.isEmpty {
                    Button { run(Self.all, orders) } label: { label(Self.all, String(localized: "全部整理")) }
                        .buttonStyle(ControlButtonStyle(kind: .primary, compact: true))
                        .disabled(!working.isEmpty)
                }
            }
            LibraryPaper {
                ForEach(library.tidies) { tidy in
                    LibraryRow(title: tidy.title, detail: workspace.detail(of: tidy, in: library)) {
                        if tidy.icon == .failure { FailureMark() } else { Image(tidy.icon).foregroundStyle(palette.ink) }
                    } trailing: {
                        if tidy.actionable(onMac: Self.onMac) {
                            Button { act(tidy) } label: { label(tidy.id, tidy.action.title, sends: tidy.action != .compare) }
                                .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
                                .disabled(working.contains(Self.all) || working.contains(tidy.id))
                        }
                    }
                }
            }
        }
    }

    /// 按钮上的字：做着时换成转圈（宽度不变）；手机上会改文件的动作带纸飞机——是发往 Mac 去做的。
    private func label(_ id: String, _ title: String, sends: Bool = true) -> some View {
        HStack(spacing: 5) {
            if Self.sends, sends { Image(.send).imageScale(.small) }
            Text(verbatim: title)
        }
        .opacity(working.contains(id) ? 0 : 1)
        .overlay { if working.contains(id) { Spinner(.mini) } }
    }

    private func act(_ tidy: LibraryTidy) {
        switch tidy.action {
        case .compare: workspace.openLibrary(.compare(tidy.id))
        case .open:
            // 手机上这一件没有按钮（`LibraryTidy.actionable`）
            #if os(macOS)
            if case .malformed(let skill, _) = tidy.kind { workspace.openSkillFile(skill.path) }
            #endif
        default: run(tidy.id, [TidyOrder(tidy: tidy.id)])
        }
    }

    private func run(_ id: String, _ orders: [TidyOrder]) {
        working.insert(id)
        Task {
            await workspace.tidy(orders, in: library)
            working.remove(id)
        }
    }

    #if os(macOS)
    private static let onMac = true
    private static let sends = false
    #else
    private static let onMac = false
    private static let sends = true
    #endif
}

/// 说明：全局说明一行（各家共读的那份），Pi 的系统提示（有才列），再是绑了文件夹的各项目；点哪一行打开它的编辑页。
struct InstructionSection: View {
    let library: AgentLibrary
    let columns: [AgentKind]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryHeader(title: Text("说明"))
            LibraryPaper {
                ForEach(library.instructions) { instruction in
                    Button { workspace.openLibrary(.instruction(instruction.kind)) } label: {
                        LibraryRow(title: workspace.instructionName(instruction.kind), detail: workspace.line(of: instruction, readers: columns)) {
                            icon(instruction.kind)
                        } trailing: {
                            if let modified = instruction.modifiedAt {
                                Text(verbatim: DateLabel.short(modified)).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize()
                            }
                            #if os(iOS)
                            Image(.forward).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                            #endif
                        }
                    }
                    .buttonStyle(.row)
                }
            }
        }
    }

    @ViewBuilder private func icon(_ kind: LibraryInstruction.Kind) -> some View {
        switch kind {
        case .global: Image(.instruction).foregroundStyle(palette.ink)
        case .piSystem: AgentKind.pi.mark.image.foregroundStyle(palette.ink)
        case .project(let id): ProjectGlyph(project: workspace.catalog?.project(id), size: Self.glyph)
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 13
    #else
    private static let glyph: CGFloat = 16
    #endif
}

/// 技能：标题写一共几个，右边是各家的列头；全局一组按分类，各项目一组，最后各家自己管的只写个数（CuePad 不碰它们）。
/// Mac 上点一行在访达里显示它的目录。
struct SkillSection: View {
    let library: AgentLibrary
    let columns: [AgentKind]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let groups = SkillGroups(library, order: workspace.catalog?.projects.map(\.id) ?? [])
        VStack(alignment: .leading, spacing: 10) {
            LibraryHeader(title: Text("技能 \(LibraryHeader<EmptyView>.count(groups.total, palette: palette))", comment: "技能清单那一组的组名，后面是个数")) {
                AgentColumns(columns: columns, header: true).padding(.trailing, LibraryPaper<EmptyView>.inset - 4)
            }
            if !groups.global.isEmpty {
                skills(groups.global.flatMap { category in [SkillLine.category(category.name)] + category.skills.map(SkillLine.skill) })
            }
            ForEach(groups.projects) { group in
                HStack(spacing: 6) {
                    ProjectGlyph(project: workspace.catalog?.project(group.project), size: 12)
                    Text(verbatim: workspace.projectName(group.project)).font(Typography.label).foregroundStyle(palette.ink2)
                    Text("\(group.skills.count)").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                }
                .padding(.horizontal, 4).padding(.top, 8)
                skills(group.skills.map(SkillLine.skill))
            }
            if !library.selfManaged.isEmpty {
                LibraryPaper {
                    ForEach(library.selfManaged, id: \.agent) { managed in
                        LibraryRow(title: managed.title, detail: String(localized: "由 \(managed.agent.name) 自己管，CuePad 不碰")) {
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

    private func skills(_ lines: [SkillLine]) -> some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                switch line {
                case .category(let name):
                    Text(verbatim: name.isEmpty ? String(localized: "不在分类里") : name)
                        .font(Typography.label).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LibraryPaper<EmptyView>.inset).padding(.top, 10).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                case .skill(let skill): SkillRow(skill: skill, columns: columns)
                }
            }
        }
        .padding(.vertical, 4)
        .paper(radius: LibraryPaper<EmptyView>.radius)
        .rowContainer(.rect(cornerRadius: LibraryPaper<EmptyView>.radius, style: .continuous))
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

/// 一个技能：名字、一句说明、右端各家一列。
private struct SkillRow: View {
    let skill: LibrarySkill
    let columns: [AgentKind]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let row = HStack(spacing: 12) {
            Text(verbatim: skill.name).font(Self.nameFont).foregroundStyle(palette.ink).lineLimit(1)
                .frame(width: Self.nameWidth, alignment: .leading)
            Text(verbatim: skill.description).font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AgentColumns(columns: columns, unseen: skill.unseenBy)
        }
        .padding(.horizontal, LibraryPaper<EmptyView>.inset)
        .frame(minHeight: Self.height)
        .contentShape(.rect)
        #if os(macOS)
        Button { workspace.revealSkill(skill.path) } label: { row }
            .buttonStyle(.row)
            .help(String(localized: "在访达中显示"))
        #else
        row.accessibilityElement(children: .combine)
        #endif
    }

    #if os(macOS)
    private static let nameFont = Typography.body.weight(.medium)
    private static let nameWidth: CGFloat = 168
    private static let height: CGFloat = 32
    #else
    private static let nameFont = Font.subheadline.weight(.medium)
    private static let nameWidth: CGFloat = 132
    private static let height: CGFloat = 40
    #endif
}
