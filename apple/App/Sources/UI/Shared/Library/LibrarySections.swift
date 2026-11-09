import CueStore
import SwiftUI

/// 改动的写入都在那台 Mac 上：手机上的动作发往 Mac（按钮带纸飞机），快照随它写回同步来。行末只画读不到这一份的那几家（`UnseenMarks`）。

/// 段名只在分段上（Mac 工具栏、手机页顶），段里不再写组名与个数。
enum LibraryLayout {
    static let column: CGFloat = 680
    static let gap = Spacing.group
    static let margin = Spacing.page
    static let bottom = Spacing.section
    #if os(macOS)
    static let radius = Radius.block
    static let paperVertical = Spacing.tight
    static let flush = false
    static let textInset: CGFloat = 24
    /// 行尾的前进箭头：Mac 上点行打开的是盖在主区上的文件页（浮层，不是进一页），不画
    static let chevron = false
    #else
    static let radius = Radius.sheet
    static let paperVertical: CGFloat = 0
    static let flush = true
    static let textInset: CGFloat = 20
    static let chevron = true
    #endif
}

struct LibraryPaper<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, LibraryLayout.paperVertical)
            .paper(cornerRadius: LibraryLayout.radius)
            .rowContainer(.rect(cornerRadius: LibraryLayout.radius), flush: LibraryLayout.flush)
    }
}


struct TidyPaper: View {
    let tidies: [LibraryTidy]
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.block) {
            TidyFacts(tidies: tidies, library: library, font: Self.font)
            HStack(spacing: Spacing.group) {
                Button { run() } label: { TidyLabel(title: "一键整理", working: working) }
                    .buttonStyle(ControlButtonStyle(kind: .primary))
                    .disabled(working)
                TidyConsequence(kind: .automatic)
            }
        }
        .padding(Spacing.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(cornerRadius: LibraryLayout.radius)
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
    private static var font: Font { Typography.secondary }
    #endif
}

struct TidyFacts: View {
    let tidies: [LibraryTidy]
    let library: AgentLibrary
    var font: Font?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var iconColumn = Chrome.icon

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            ForEach(tidies) { tidy in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.group) {
                    Image(tidy.icon).foregroundStyle(palette.ink2).frame(width: iconColumn)
                    Text(verbatim: workspace.fact(of: tidy, in: library)).font(font).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

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
        .animation(Motion.fade, value: tidies.isEmpty)
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

/// 整理按钮旁的后果（操作前必须知道的，不藏进问号）：去重、合并有东西进废纸篓；手机上发往 Mac 去做，做完撤不回（那台照做不留撤销，`MacExecutor`）。
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
            LinkRow(title: Text(verbatim: workspace.instructionName(instruction.kind)), chevron: LibraryLayout.chevron) {
                InstructionIcon(kind: instruction.kind)
            } trailing: {
                InstructionTrailing(library: library, instruction: instruction)
            }
        }
        .buttonStyle(.row)
    }
}

/// 正文读同步来的那一条（`LibraryFileText`），不另存一份预览。
private struct GlobalRuleRow: View {
    let library: AgentLibrary
    let instruction: LibraryInstruction
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var iconColumn = Chrome.icon
    @State private var texts: [String: String]?

    var body: some View {
        Button { workspace.openLibrary(.instruction(.global)) } label: {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.group) {
                    InstructionIcon(kind: .global).frame(width: iconColumn)
                    Text(verbatim: workspace.instructionName(.global)).font(Typography.body).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InstructionTrailing(library: library, instruction: instruction)
                    if LibraryLayout.chevron { Chevron(.forward).foregroundStyle(palette.ink3) }
                }
                Text(opening)
                    .font(Typography.meta).foregroundStyle(instruction.hash == nil ? palette.ink3 : palette.ink2)
                    .lineLimit(Self.lines, reservesSpace: true).lineSpacing(Typography.noteLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, iconColumn + Spacing.group)
            }
            .padding(.horizontal, Spacing.inset)
            .padding(.vertical, Spacing.group)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .observingLibraryTexts([instruction.path], in: library, into: $texts)
    }

    private static let lines = 4

    private var opening: AttributedString {
        guard let arrived = AgentLibrary.arrived(instruction.path, hash: instruction.hash, in: texts) else { return "" }
        guard let text = arrived else { return AttributedString(localized: "还没有") }
        var lines: [AttributedString] = []
        func add(_ line: String, bold: Bool = false) {
            let plain = MarkdownBlock.plainInline(line).trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty, lines.count < Self.lines else { return }
            var shown = AttributedString(plain)
            if bold { shown.inlinePresentationIntent = .stronglyEmphasized }
            lines.append(shown)
        }
        _ = MarkdownBlock.parse(text) { block in
            switch block.content {
            case .heading(_, let text): add(text, bold: true)
            case .paragraph(let text), .quote(let text): text.split(separator: "\n").forEach { add(String($0)) }
            case .code, .table, .rule: break
            }
            return lines.count < Self.lines
        }
        return lines.reduce(into: AttributedString()) { all, line in
            if !all.characters.isEmpty { all += "\n" }
            all += line
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
        case .project(let id): ProjectGlyph(project: workspace.catalog?.project(id), size: Self.glyph)
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 13
    #else
    private static let glyph: CGFloat = 16
    #endif
}

private struct InstructionTrailing: View {
    let library: AgentLibrary
    let instruction: LibraryInstruction
    @Environment(\.palette) private var palette

    var body: some View {
        if instruction.hash == nil {
            Text("还没有").font(Typography.meta).foregroundStyle(palette.ink3).fixedSize()
        } else {
            let writers = library.merge(into: instruction.kind)?.writers ?? []
            let unseen = library.unseen(instruction)
            UnseenMarks(agents: library.agents, unseen: library.agents.filter { unseen.contains($0) || writers.contains($0) })
        }
    }
}
