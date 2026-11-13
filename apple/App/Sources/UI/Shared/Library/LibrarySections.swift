import CueStore
import SwiftUI

/// 改动的写入都在那台 Mac 上：手机上的动作发往 Mac（按钮带纸飞机），快照随它写回同步来。

/// 段名只在分段上（Mac 工具栏、手机页顶）。页上没有纸也没有卡：分组小标题与行（`LibraryEntry`）直接排在桌面上，靠间距分组。
enum LibraryLayout {
    /// 这一页与文件页正文同一列（同灵感的编辑页）。
    static let column: CGFloat = 680
    static let gap = Spacing.section
    static let margin = Spacing.page
    static let bottom = Spacing.section
    #if os(macOS)
    static let textInset: CGFloat = 24
    /// 行尾的前进箭头：Mac 上点行打开的是盖在主区上的文件页（浮层，不是进一页），不画
    static let chevron = false
    #else
    static let textInset: CGFloat = 20
    static let chevron = true
    #endif
}

/// 一组：小标题（可带个数、行尾可带一颗钮）与它下面的行。
struct LibraryGroup<Label: View, Action: View, Content: View>: View {
    var count: Int?
    @ViewBuilder var label: Label
    @ViewBuilder var action: Action
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.item) {
                HStack(spacing: Spacing.glyph) {
                    label.foregroundStyle(palette.ink2)
                    if let count { Text(verbatim: "\(count)").monospacedDigit().foregroundStyle(palette.ink3) }
                }
                .font(Typography.label)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                action
            }
            .frame(minHeight: ControlSize.inline.height)
            VStack(spacing: 0) { content }
        }
    }
}

extension LibraryGroup where Action == EmptyView {
    init(count: Int? = nil, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        self.init(count: count, label: label, action: { EmptyView() }, content: content)
    }
}

/// 纸上的一行：图标垫一小块底、名字、下面一行灰字。
struct LibraryEntry<Icon: View, Trailing: View>: View {
    let title: String
    var dim = false
    let detail: String
    /// 灰字那行放不下时一直折下去（整理的那几件要读全），不然最多两行。
    var wraps = false
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.group) {
            icon.frame(width: Self.tile, height: Self.tile).background(palette.fill, in: .rect(cornerRadius: Radius.chip)).readerHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(verbatim: title).font(Typography.body.weight(.medium)).foregroundStyle(dim ? palette.ink3 : palette.ink).lineLimit(1)
                Text(verbatim: detail).font(Typography.meta).foregroundStyle(dim ? palette.ink3 : palette.ink2)
                    .lineLimit(wraps ? nil : 2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, Spacing.item)
        .contentShape(.rect)
    }

    /// 图标底的边长：两行字的高。
    #if os(macOS)
    private static var tile: CGFloat { 32 }
    #else
    private static var tile: CGFloat { 36 }
    #endif
}

/// 该整理的那几件就是纸上最前面的一组行：标题行尾一颗小钮。整理完这一组收起、下面的跟着上移（是你点了才变的）。
struct TidySlot: View {
    let library: AgentLibrary
    let rules: Bool
    @Environment(Workspace.self) private var workspace
    @State private var working = false

    var body: some View {
        let tidies = library.automaticTidies.filter { ($0.instruction != nil) == rules }
        // Group：这一段没有时不占位置
        Group {
            if !tidies.isEmpty {
                LibraryGroup(count: tidies.count) {
                    Text("可以整理")
                } action: {
                    Button { run(tidies) } label: { TidyLabel(title: "一键整理", working: working) }
                        .buttonStyle(ControlButtonStyle(kind: .primary, size: .inline))
                        .disabled(working)
                } content: {
                    TidyFacts(tidies: tidies, library: library)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: tidies.isEmpty)
    }

    private func run(_ tidies: [LibraryTidy]) {
        working = true
        Task {
            await workspace.tidy(tidies.map { TidyOrder(tidy: $0.id) }, in: library)
            working = false
        }
    }
}

/// 每件两行：哪里不对、一键整理会对它做什么（`TidyFact`）。点之前就看得到会动哪几个，不另开说明。
struct TidyFacts: View {
    let tidies: [LibraryTidy]
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tidies) { tidy in
                let fact = workspace.fact(of: tidy, in: library)
                LibraryEntry(title: fact.problem, detail: fact.plan, wraps: true) {
                    Image(tidy.icon).foregroundStyle(palette.ink2)
                } trailing: {
                    EmptyView()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct TidyLabel: View {
    let title: LocalizedStringResource
    let working: Bool

    var body: some View {
        HStack(spacing: Spacing.glyph) {
            #if os(iOS)
            Image(.send).imageScale(.small)
            #endif
            Text(title)
        }
        .opacity(working ? 0 : 1)
        .overlay { if working { Spinner(.mini) } }
    }
}

/// 去重、合并按钮旁的后果（操作前必须知道的）：有东西进废纸篓；手机上发往 Mac 去做，做完撤不回（那台照做不留撤销，`MacExecutor`）。
struct TidyConsequence: View {
    enum Kind { case duplicate, merge }

    let kind: Kind
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).font(Typography.meta).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private var text: LocalizedStringResource {
        #if os(macOS)
        switch kind {
        case .duplicate: "其余几份进废纸篓"
        case .merge: "原来那份进废纸篓"
        }
        #else
        switch kind {
        case .duplicate: "其余几份进废纸篓，撤不回"
        case .merge: "原来那份进废纸篓，撤不回"
        }
        #endif
    }
}

/// 全局规则与各家自己那几份同在"全局"一组，全局规则排第一。
struct InstructionSection: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let projects = library.instructions.filter { if case .project = $0.kind { true } else { false } }
        let global = library.instructions.filter { $0.kind == .global } + library.instructions.filter { if case .agent = $0.kind { true } else { $0.kind == .piSystem } }
        VStack(alignment: .leading, spacing: LibraryLayout.gap) {
            TidySlot(library: library, rules: true)
            if !global.isEmpty {
                LibraryGroup { Text("全局") } content: { ForEach(global) { row($0) } }
            }
            if !projects.isEmpty {
                LibraryGroup { Text("项目") } content: { ForEach(projects) { row($0) } }
            }
        }
    }

    private func row(_ instruction: LibraryInstruction) -> some View {
        Button { workspace.openLibrary(.instruction(instruction.kind)) } label: {
            LibraryEntry(title: name(instruction.kind), dim: instruction.hash == nil, detail: detail(instruction)) {
                InstructionIcon(kind: instruction.kind)
            } trailing: {
                if LibraryLayout.chevron { Chevron(.forward).foregroundStyle(palette.ink3) }
            }
        }
        .buttonStyle(.row)
    }

    /// 各家自己那份的文件名在下面那行，名字不带。
    private func name(_ kind: LibraryInstruction.Kind) -> String {
        if case .agent(let agent, _) = kind { String(localized: "\(agent.name) 的全局规则") } else { workspace.instructionName(kind) }
    }

    /// 文件名，再用字写谁读（不画记号）：全局规则写谁在读、谁另写了一份（点开在文件页顶上合并，`MergeBar`），项目规则写哪几家读不到。
    private func detail(_ instruction: LibraryInstruction) -> String {
        guard instruction.hash != nil else { return String(localized: "还没有") }
        let file = URL(filePath: instruction.path).lastPathComponent
        let writers = library.merge(into: instruction.kind)?.writers ?? []
        func list(_ agents: [AgentKind]) -> String { agents.map(\.name).formatted(.list(type: .and)) }
        switch instruction.kind {
        case .agent(_, let file): return file
        case .piSystem: return file
        case .global:
            let reading = library.agents.filter { instruction.readers.contains($0) && !writers.contains($0) }
            return Dotted(
                file, reading.isEmpty ? nil : String(localized: "\(list(reading)) 在读"),
                writers.isEmpty ? nil : String(localized: "\(list(writers)) 另写了一份")
            ).visible
        case .project:
            let unseen = library.unseen(instruction)
            let missing = library.agents.filter { unseen.contains($0) || writers.contains($0) }
            return Dotted(file, missing.isEmpty ? nil : String(localized: "\(list(missing)) 读不到")).visible
        }
    }
}

private struct InstructionIcon: View {
    let kind: LibraryInstruction.Kind
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        switch kind {
        case .global: Image(.instruction).foregroundStyle(palette.ink)
        case .piSystem: AgentKind.pi.mark.image.foregroundStyle(palette.ink)
        case .agent(let agent, _): agent.mark.image.foregroundStyle(palette.ink)
        case .project(let id): ProjectGlyph(project: workspace.catalog?.project(id), size: Self.glyph)
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 13
    #else
    private static let glyph: CGFloat = 16
    #endif
}
