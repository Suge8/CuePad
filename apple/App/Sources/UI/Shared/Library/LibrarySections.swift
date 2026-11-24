import CueStore
import SwiftUI

enum LibraryLayout {
    static let column: CGFloat = 680
    static let gap = Spacing.section
    static let margin = Spacing.page
    static let bottom = Spacing.section
    static let textInset = Spacing.page
    #if os(macOS)
    static let chevron = false
    #else
    static let chevron = true
    #endif
}

struct LibraryGroup<Lead: View, Action: View, Content: View>: View {
    let title: Dotted
    var count: Int?
    @ViewBuilder var lead: Lead
    @ViewBuilder var action: Action
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.glyph) {
                lead.readerHidden(true)
                SectionHeader(title, level: .group, count: count) { action }
            }
            .frame(minHeight: ControlSize.inline.height)
            VStack(spacing: 0) { content }
        }
    }
}

extension LibraryGroup where Lead == EmptyView {
    init(_ title: Dotted, count: Int? = nil, @ViewBuilder content: () -> Content, @ViewBuilder action: () -> Action) {
        self.init(title: title, count: count, lead: { EmptyView() }, action: action, content: content)
    }
}

extension LibraryGroup where Action == EmptyView {
    init(_ title: Dotted, count: Int? = nil, @ViewBuilder lead: () -> Lead, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, lead: lead, action: { EmptyView() }, content: content)
    }
}

extension LibraryGroup where Lead == EmptyView, Action == EmptyView {
    init(_ title: Dotted, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, lead: { EmptyView() }, action: { EmptyView() }, content: content)
    }
}

struct LibraryEntry<Icon: View, Trailing: View>: View {
    let title: String
    var dim = false
    let detail: String
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

    #if os(macOS)
    private static var tile: CGFloat { 32 }
    #else
    private static var tile: CGFloat { 36 }
    #endif
}

struct TidySlot: View {
    let library: AgentLibrary
    let rules: Bool
    @Environment(Workspace.self) private var workspace
    @State private var working = false

    var body: some View {
        let tidies = library.automaticTidies.filter { ($0.instruction != nil) == rules }
        Group {
            if !tidies.isEmpty {
                LibraryGroup(Dotted(String(localized: "可以整理")), count: tidies.count) {
                    TidyFacts(tidies: tidies, library: library)
                } action: {
                    Button { run(tidies) } label: { TidyLabel(title: "一键整理", working: working) }
                        .buttonStyle(ControlButtonStyle(kind: .primary, size: .inline))
                        .disabled(working)
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
                LibraryGroup(Dotted(String(localized: "全局"))) { ForEach(global) { row($0) } }
            }
            if !projects.isEmpty {
                LibraryGroup(Dotted(String(localized: "项目"))) { ForEach(projects) { row($0) } }
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

    private func name(_ kind: LibraryInstruction.Kind) -> String {
        if case .agent(let agent, _) = kind { String(localized: "\(agent.name) 的全局规则") } else { workspace.instructionName(kind) }
    }

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
