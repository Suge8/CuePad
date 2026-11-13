import CueStore
import SwiftUI

/// 改动的写入都在那台 Mac 上：手机上的动作发往 Mac（按钮带纸飞机），快照随它写回同步来。全局规则那张写谁在读（`ReaderMarks`），其余行末只画读不到这一份的那几家（`UnseenMarks`）。

/// 段名只在分段上（Mac 工具栏、手机页顶）。规则同项目页的灵感墙一个样：分组标题下面一面卡片墙（`LibraryWall`、`LibraryCard`），
/// 全局规则是墙上面通栏的那一张；技能多，排成清单不套卡；着色的那块是要你点一下的整理。
enum LibraryLayout {
    /// 文件页正文那一列（同灵感的编辑页）。
    static let column: CGFloat = 680
    static let gap = Spacing.section
    static let margin = Spacing.page
    static let bottom = Spacing.section
    #if os(macOS)
    static let radius = Radius.block
    static let textInset: CGFloat = 24
    #else
    static let radius = Radius.sheet
    static let textInset: CGFloat = 20
    #endif
}

/// 一组：标题（可带个数，同项目页的"最近 13"）与它下面的墙或清单。
struct LibraryGroup<Label: View, Content: View>: View {
    var count: Int?
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                label.font(Typography.sectionTitle).foregroundStyle(palette.ink)
                if let count { Text(verbatim: "\(count)").font(Typography.sectionCount).foregroundStyle(palette.ink3) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct TidyCallout: View {
    let tidies: [LibraryTidy]
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            HStack(spacing: Spacing.item) {
                Text("\(tidies.count) 件可以整理").font(Typography.label).foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { run() } label: { TidyLabel(title: "一键整理", working: working) }
                    .buttonStyle(ControlButtonStyle(kind: .primary, size: .compact))
                    .disabled(working)
            }
            TidyFacts(tidies: tidies, library: library)
        }
        .padding(.leading, CardFaceMetrics.padding).padding(.trailing, Spacing.group).padding(.vertical, Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.bubble, in: .rect(cornerRadius: Radius.card))
    }

    private func run() {
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
    @ScaledMetric(relativeTo: .body) private var iconColumn = Chrome.icon

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            ForEach(tidies) { tidy in
                let fact = workspace.fact(of: tidy, in: library)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.group) {
                    Image(tidy.icon).foregroundStyle(palette.ink2).frame(width: iconColumn)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(verbatim: fact.problem).font(Typography.body).foregroundStyle(palette.ink)
                        Text(verbatim: fact.plan).font(Typography.meta).foregroundStyle(palette.ink2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
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
        // Group：这一段没有时不占位置
        Group {
            if !tidies.isEmpty { TidyCallout(tidies: tidies, library: library).transition(.opacity) }
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

/// 各份正文读同步来的那一条（`LibraryFileText`），对上快照的哈希才画摘要，不另存一份预览。
struct InstructionSection: View {
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var texts: [String: String]?

    var body: some View {
        let projects = library.instructions.filter { if case .project = $0.kind { true } else { false } }
        let own = library.instructions.filter { if case .agent = $0.kind { true } else { $0.kind == .piSystem } }
        VStack(alignment: .leading, spacing: LibraryLayout.gap) {
            TidySlot(library: library, rules: true)
            if let global = library.instruction(.global) { GlobalRule(library: library, instruction: global, text: text(of: global)) }
            if !own.isEmpty {
                LibraryGroup { Text("各家自己的") } content: { LibraryWall { ForEach(own) { card($0) } } }
            }
            if !projects.isEmpty {
                LibraryGroup { Text("项目") } content: { LibraryWall { ForEach(projects) { card($0) } } }
            }
        }
        .observingLibraryTexts(library.instructions.map(\.path), in: library, into: $texts)
    }

    /// 还没到（快照先到了）与还没有这个文件都是 nil。
    private func text(of instruction: LibraryInstruction) -> String? {
        AgentLibrary.arrived(instruction.path, hash: instruction.hash, in: texts) ?? nil
    }

    private func card(_ instruction: LibraryInstruction) -> some View {
        let summary = text(of: instruction).map(CardText.init)
        return LibraryCard(
            title: name(instruction.kind), dim: instruction.hash == nil,
            preview: instruction.hash == nil ? String(localized: "还没有") : summary.map { $0.preview.isEmpty ? $0.title : $0.preview } ?? ""
        ) {
            workspace.openLibrary(.instruction(instruction.kind))
        } lead: {
            InstructionIcon(kind: instruction.kind)
        } meta: {
            if instruction.hash != nil {
                HStack(spacing: Spacing.item) {
                    Text(verbatim: Self.fileName(instruction)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if case .project = instruction.kind {
                        let writers = library.merge(into: instruction.kind)?.writers ?? []
                        let unseen = library.unseen(instruction)
                        UnseenMarks(agents: library.agents, unseen: library.agents.filter { unseen.contains($0) || writers.contains($0) })
                    }
                }
            }
        }
    }

    /// 各家自己那份的文件名在卡的脚注里，标题不带。
    private func name(_ kind: LibraryInstruction.Kind) -> String {
        if case .agent(let agent, _) = kind { String(localized: "\(agent.name) 的全局规则") } else { workspace.instructionName(kind) }
    }

    private static func fileName(_ instruction: LibraryInstruction) -> String {
        if case .agent(_, let file) = instruction.kind { file } else { URL(filePath: instruction.path).lastPathComponent }
    }
}

/// 这一页的焦点：各家共读的那一份，墙上面通栏的一张。标题旁画谁在读，正文开头往下渐隐（点开是全文），脚注写谁在读、放在哪；
/// 有哪家另写了一份、内容不一样时脚注下多一行（点开就在文件页顶上合并，`MergeBar`）。
private struct GlobalRule: View {
    let library: AgentLibrary
    let instruction: LibraryInstruction
    let text: String?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let writers = library.merge(into: .global)?.writers ?? []
        let reading = instruction.hash == nil ? [] : library.agents.filter { instruction.readers.contains($0) && !writers.contains($0) }
        Button { workspace.openLibrary(.instruction(.global)) } label: {
            VStack(alignment: .leading, spacing: Spacing.group) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                    Text("全局规则").font(Typography.title).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if instruction.hash != nil { ReaderMarks(agents: library.agents, reading: reading) }
                }
                if instruction.hash == nil {
                    Text("还没有，点开来写").font(Typography.body).foregroundStyle(palette.ink3)
                } else {
                    Text(opening)
                        .font(Typography.body).foregroundStyle(palette.ink2)
                        .lineLimit(Self.lines, reservesSpace: true).lineSpacing(Typography.noteLineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                }
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(verbatim: Dotted(Self.readers(reading), library.shown(instruction.path)).visible)
                        .foregroundStyle(palette.ink3).lineLimit(1).truncationMode(.middle)
                    if !writers.isEmpty {
                        HStack(spacing: Spacing.glyph) {
                            ForEach(writers, id: \.self) { $0.mark.image }
                            Text(verbatim: String(localized: "\(writers.map(\.name).formatted(.list(type: .and))) 另写了一份，点开合并")).lineLimit(2)
                        }
                        .foregroundStyle(palette.ink)
                    }
                }
                .font(Typography.meta)
            }
            .multilineTextAlignment(.leading)
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper()
            .contentShape(.rect(cornerRadius: Radius.card))
        }
        .cardButton()
        .accessibilityElement(children: .combine)
    }

    /// 渐隐只吃掉最后两行：四行以内的短文件看得全。
    private static let lines = 6
    #if os(macOS)
    private static let padding = Spacing.panel
    #else
    private static let padding = Spacing.block
    #endif

    private static func readers(_ reading: [AgentKind]) -> String? {
        reading.isEmpty ? nil : String(localized: "\(reading.map(\.name).formatted(.list(type: .and))) 在读")
    }

    private var opening: AttributedString {
        guard let text else { return "" }
        var lines: [AttributedString] = []
        func add(_ line: String, bold: Bool = false) {
            let plain = MarkdownBlock.plainInline(line).trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty, lines.count < Self.lines else { return }
            var shown = AttributedString(plain)
            if bold {
                shown.inlinePresentationIntent = .stronglyEmphasized
                shown.foregroundColor = palette.ink
            }
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
        case .agent(let agent, _): agent.mark.image.foregroundStyle(palette.ink)
        case .project(let id): ProjectGlyph(project: workspace.catalog?.project(id), size: Self.glyph)
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 13
    #else
    private static let glyph: CGFloat = 12
    #endif
}
