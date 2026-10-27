import CueStore
import SwiftUI

/// 技能与规则页的几块（Mac 的页与手机的页同一份，两段怎么挂、怎么换在 `LibraryDeck`，`LibraryPage`、`LibraryScreen` 只管页顶与空着时）：
/// 一键整理那块纸（只在有不用你选的几件时出现，`TidyPaper`）、规则（`InstructionSection`）、技能（`SkillSection`）。
/// 点任何一份都在 CuePad 里打开它的文件页（`LibraryFilePage`、`LibraryFileScreen`）；去重与合并在文件页顶上那一条里做。
/// 改动的写入都在那台 Mac 上：手机上的动作发往 Mac（按钮带纸飞机），快照随它写回同步来。行末只画读不到这一份的那几家（`UnseenMarks`）。

/// 两段共用的排版：一列居中、最宽 `column`（同 Mac 文件页那一列字），块与块之间 `gap`。段名只在分段上（Mac 工具栏、手机页顶），段里不再写组名与个数。
enum LibraryLayout {
    static let column: CGFloat = 680
    static let gap: CGFloat = 12
    #if os(macOS)
    static let margin: CGFloat = Spacing.page
    static let bottom: CGFloat = Spacing.section
    #else
    static let margin: CGFloat = 16
    static let bottom: CGFloat = 24
    #endif
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
    static let height: CGFloat = 44
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

/// 一键整理那块纸：按段分开，规则段只列规则的事（内容相同换链接、Claude Code 读不到项目规则），技能段只列技能的事（旧目录、读不到、空文件夹），
/// 那一段没有就不出现，有就在那一段最上面。不用你选的那几件逐条写结果的事实，不带逐条的按钮、不写标题，
/// 底下一颗"一键整理"只做这一块列出的。手机上按钮旁直写后果（`TidyConsequence`）；Mac 做完给可撤销的提示（`Workspace.tidy`）。
struct TidyPaper: View {
    let tidies: [LibraryTidy]
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tidies) { tidy in
                    HStack(alignment: .firstTextBaseline, spacing: LibraryRowMetrics.gap) {
                        Image(tidy.icon).foregroundStyle(palette.ink2).frame(width: LibraryRowMetrics.icon)
                        Text(verbatim: workspace.fact(of: tidy, in: library)).font(Self.font).foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 12) {
                Button { run() } label: { TidyLabel(title: "一键整理", working: working) }
                    .buttonStyle(ControlButtonStyle(kind: .primary))
                    .disabled(working)
                TidyConsequence(kind: .automatic)
            }
        }
        .padding(LibraryPaper<EmptyView>.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: LibraryPaper<EmptyView>.radius)
    }

    private func run() {
        working = true
        Task {
            await workspace.tidy(tidies.map { TidyOrder(tidy: $0.id) }, in: library)
            working = false
        }
    }

    #if os(macOS)
    private static var font: Font { Typography.body }
    #else
    private static var font: Font { .subheadline }
    #endif
}

/// 一键整理那块纸摆在一段的最上面，只放这一段的事（`rules`：规则的，否则技能的）。
/// 整理完收起时淡出、下面的跟着上移：是你点了才变的。
struct TidySlot: View {
    let library: AgentLibrary
    let rules: Bool

    var body: some View {
        let tidies = library.automaticTidies.filter { ($0.instruction != nil) == rules }
        // Group：这一段没有时不占位置，那一段的间距也不多出一格
        Group {
            if !tidies.isEmpty { TidyPaper(tidies: tidies, library: library).transition(.opacity).padding(.bottom, LibraryLayout.gap) }
        }
        .animation(HandOff.quick, value: tidies.isEmpty)
    }
}

/// 整理那几颗按钮上的字：做着时换成转圈（宽度不变）；手机上带纸飞机——是发往 Mac 去做的。
struct TidyLabel: View {
    let title: LocalizedStringResource
    let working: Bool

    var body: some View {
        HStack(spacing: 5) {
            #if os(iOS)
            Image(.send).imageScale(.small)
            #endif
            Text(title)
        }
        .opacity(working ? 0 : 1)
        .overlay { if working { Spinner(.mini) } }
    }
}

/// 整理按钮旁的后果（操作前必须知道的，不藏进问号）：去重、合并有东西进废纸篓；手机上发往 Mac 去做，做完撤不回（那台照做不留撤销，`MacExecutor`）。
/// Mac 上做完给可撤销的提示，一键整理不另写。
struct TidyConsequence: View {
    enum Kind { case automatic, duplicate, merge }

    let kind: Kind
    @Environment(\.palette) private var palette

    var body: some View {
        if let text {
            Text(text).font(Typography.meta).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: LocalizedStringResource? {
        #if os(macOS)
        switch kind {
        case .automatic: nil
        case .duplicate: "其余几份进废纸篓"
        case .merge: "原来那份进废纸篓"
        }
        #else
        switch kind {
        case .automatic: "在 Mac 上做，做完撤不回"
        case .duplicate: "其余几份进废纸篓，撤不回"
        case .merge: "原来那份进废纸篓，撤不回"
        }
        #endif
    }
}

/// 规则：全局规则是一张露出正文开头几行的纸，Pi 的系统提示（有才列）接在它下面；绑了文件夹的各项目另一张纸，各一行。点哪一份都打开它的文件页。
/// 行末是读不到这一份的那几家，内容不同、另写了一份的那家也在内（文件页顶上那一条里合并进来）；Pi 的系统提示不画。
struct InstructionSection: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let projects = library.instructions.filter { if case .project = $0.kind { true } else { false } }
        VStack(alignment: .leading, spacing: LibraryLayout.gap) {
            TidySlot(library: library, rules: true)
            LibraryPaper {
                if let global = library.instruction(.global) { GlobalRuleRow(library: library, instruction: global) }
                if let pi = library.instruction(.piSystem) { row(pi) }
            }
            if !projects.isEmpty {
                LibraryPaper { ForEach(projects) { row($0) } }
            }
        }
    }

    private func row(_ instruction: LibraryInstruction) -> some View {
        Button { workspace.openLibrary(.instruction(instruction.kind)) } label: {
            LibraryRow(title: workspace.instructionName(instruction.kind), detail: nil) {
                InstructionIcon(kind: instruction.kind)
            } trailing: {
                InstructionTrailing(library: library, instruction: instruction)
            }
        }
        .buttonStyle(.row)
    }
}

/// 全局规则那一张纸：名字一行，下面露出正文开头四行（留足四行的高，短的不缩），点开就改。
private struct GlobalRuleRow: View {
    let library: AgentLibrary
    let instruction: LibraryInstruction
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button { workspace.openLibrary(.instruction(.global)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: LibraryRowMetrics.gap) {
                    InstructionIcon(kind: .global).frame(width: LibraryRowMetrics.icon)
                    Text(verbatim: workspace.instructionName(.global)).font(Self.titleFont).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InstructionTrailing(library: library, instruction: instruction)
                }
                Text(verbatim: Self.opening(instruction.text) ?? String(localized: "还没有"))
                    .font(Self.textFont).foregroundStyle(instruction.text == nil ? palette.ink3 : palette.ink2)
                    .lineLimit(Self.lines, reservesSpace: true).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, LibraryRowMetrics.icon + LibraryRowMetrics.gap)
            }
            .padding(.horizontal, LibraryPaper<EmptyView>.inset)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }

    private static let lines = 4

    /// 正文开头几行（跳过空行）。
    private static func opening(_ text: String?) -> String? {
        text.map { $0.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(lines).joined(separator: "\n") }
    }

    #if os(macOS)
    private static var titleFont: Font { Typography.body.weight(.medium) }
    private static var textFont: Font { Typography.meta }
    #else
    private static var titleFont: Font { .body }
    private static var textFont: Font { .footnote }
    #endif
}

/// 规则行首的图：全局规则一张纸，Pi 的系统提示是 Pi 的标志，项目是它的图形。
private struct InstructionIcon: View {
    let kind: LibraryInstruction.Kind
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
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

/// 规则行末：读不到的那几家与另写了一份的那家（还没有这个文件时写"还没有"），手机上再一个箭头。
private struct InstructionTrailing: View {
    let library: AgentLibrary
    let instruction: LibraryInstruction
    @Environment(\.palette) private var palette

    var body: some View {
        if instruction.text == nil {
            Text("还没有").font(Typography.meta).foregroundStyle(palette.ink3).fixedSize()
        } else {
            let writers = library.merge(into: instruction.kind)?.writers ?? []
            let unseen = library.unseen(instruction)
            UnseenMarks(agents: library.agents, unseen: library.agents.filter { unseen.contains($0) || writers.contains($0) })
        }
        #if os(iOS)
        Image(.forward).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
        #endif
    }
}
