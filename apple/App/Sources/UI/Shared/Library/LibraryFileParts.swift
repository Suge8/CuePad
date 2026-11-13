import CueEditor
import CueStore
import SwiftUI


struct DuplicateBar: View {
    let path: String
    let tidy: LibraryTidy
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @State private var working = false

    var body: some View {
        if case .duplicate(_, let copies) = tidy.kind {
            LibraryFileBar {
                PaneSegment(items: copies.map { .init(value: $0.path, verbatim: workspace.copyName($0, among: copies)) }, selection: path) {
                    workspace.openLibrary(.skill($0))
                }
                .fixedSize()
                .paneSlot(.compact)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("几份同名的")
                Spacer(minLength: 8)
                Button { keep() } label: { TidyLabel(title: "只留这份", working: working) }
                    .buttonStyle(ControlButtonStyle(kind: .primary, size: .compact))
                    .disabled(working)
            }
        }
    }

    private func keep() {
        working = true
        Task {
            await workspace.tidy([TidyOrder(tidy: tidy.id, keep: path)], in: library)
            working = false
        }
    }
}

/// 合并照那台 Mac 此刻的文件做，请求带着你看过的那一版（`TidyOrder.base`）：Mac 上先写下没存的字，手机上有没发的改动时不让合并（你的字会变成和它冲突）。
/// 标出合并稿时，有替换基础提示的那几份才多出第二行（要不要一并合并）。
struct MergeBar: View {
    let tidy: LibraryTidy
    let library: AgentLibrary
    let draft: FileDraft
    let texts: [String: String]?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var working = false

    var body: some View {
        LibraryFileBar {
            HStack(spacing: Spacing.glyph) {
                ForEach(tidy.writers, id: \.self) { $0.mark.image.foregroundStyle(palette.ink2) }
                Text(verbatim: String(localized: "\(tidy.writers.map(\.name).formatted(.list(type: .and))) 另写了一份"))
                    .font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(2)
            }
            Spacer(minLength: 8)
            if draft.previewing {
                Button("取消") { draft.previewing = false }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .compact))
                    .disabled(working)
            }
            Button { merge() } label: { TidyLabel(title: draft.previewing ? "合并" : "合并进来", working: working) }
                .buttonStyle(ControlButtonStyle(kind: draft.previewing ? .primary : .secondary, size: .compact))
                .disabled(working || tidy.preview(retiring: draft.retire, texts: texts) == nil || Self.unsent(draft))
        } below: {
            let replacements = tidy.sources.map(\.origin).filter(\.replacesBasePrompt)
            if draft.previewing, !replacements.isEmpty {
                HStack(spacing: Spacing.item) {
                    ForEach(replacements, id: \.self) { origin in
                        let on = draft.retire.contains(origin)
                        Button {
                            if on { draft.retire.remove(origin) } else { draft.retire.insert(origin) }
                        } label: {
                            Text(verbatim: String(localized: "也合并 \(workspace.replacementName(origin))")).chip(on: on)
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .disabled(working)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: draft.previewing)
    }

    private func merge() {
        guard draft.previewing else {
            draft.previewing = true
            return
        }
        working = true
        Task {
            await draft.leave()
            await workspace.tidy([TidyOrder(tidy: tidy.id, retire: draft.retire, base: tidy.base)], in: library)
            working = false
            draft.previewing = false
        }
    }

    private static func unsent(_ draft: FileDraft) -> Bool {
        #if os(iOS)
        draft.dirty
        #else
        false
        #endif
    }
}

struct ConflictBar: View {
    let draft: FileDraft
    @Environment(\.palette) private var palette

    var body: some View {
        LibraryFileBar {
            Text(Self.fact).font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(2)
            Spacer(minLength: 8)
            if case .conflict(_?) = draft.state {
                Button(Self.take) { draft.takeFile() }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .compact))
                Button("留我的") { Task { await draft.keepMine() } }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .compact))
            }
        }
    }

    #if os(macOS)
    private static let fact: LocalizedStringResource = "文件在别处改过了"
    private static let take: LocalizedStringResource = "换成文件里的"
    #else
    private static let fact: LocalizedStringResource = "Mac 上改过了，你改的还没发"
    private static let take: LocalizedStringResource = "换成 Mac 上的"
    #endif
}

/// 文件页顶上的一条（同名的几份、另写了一份、改冲突了、起步规则）：一句话与行尾的小钮，直接排在页上，不垫底、不套卡（同列表页的分组标题行）。
struct LibraryFileBar<Content: View, Below: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            HStack(spacing: Spacing.item) { content }.frame(minHeight: ControlSize.compact.height)
            below
        }
    }
}

extension LibraryFileBar where Below == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, below: { EmptyView() })
    }
}

/// 字、标题（前面淡墨的 #）与这一列的宽同编辑器（`theme`）：从编辑器换过来字不跳大小、不挪位置。
struct MergePreview: View {
    let blocks: [(text: String, incoming: Bool)]
    let theme: CueEditorTheme
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    private var resolvedTheme: CueEditorTheme {
        #if os(iOS)
        theme.scaled(for: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
        #else
        theme
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    HStack(alignment: .top, spacing: Self.gap) {
                        Capsule().fill(block.incoming ? palette.ink2 : .clear).frame(width: Self.bar)
                        text(block.text).foregroundStyle(palette.ink).lineSpacing(resolvedTheme.lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, Spacing.tight).padding(.trailing, Spacing.tight).padding(.leading, Self.mark)
                    .background(block.incoming ? palette.bubble : .clear, in: .rect(cornerRadius: Radius.chip))
                    // 记号与底挂在字的左边：字与编辑器里的对齐
                    .padding(.leading, -(Self.mark + Self.bar + Self.gap))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(block.incoming ? String(localized: "会并进来") : "")
                }
            }
            .padding(.vertical, Spacing.group)
            .frame(maxWidth: theme.maxTextWidth, alignment: .leading)
            .padding(.horizontal, theme.horizontalInset)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
    }

    private static let mark: CGFloat = 4
    private static let bar: CGFloat = 3
    private static let gap: CGFloat = 8

    private func text(_ block: String) -> Text {
        let marks = block.prefix { $0 == "#" }
        guard !marks.isEmpty, !block.contains("\n"), block.dropFirst(marks.count).first == " " else {
            return Text(verbatim: block).font(Font(resolvedTheme.font as CTFont))
        }
        return Text("\(Text(verbatim: String(marks) + " ").foregroundStyle(palette.ink3))\(Text(verbatim: String(block.dropFirst(marks.count + 1))))")
            .font(Font(resolvedTheme.headingFont as CTFont))
    }
}

struct SkillFields: View {
    let draft: FileDraft
    let problem: SkillProblem?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            TextField(String(localized: "名字"), text: Binding(get: { draft.name }, set: { draft.changed(name: $0) }), palette: palette)
                .textFieldStyle(.plain).font(Self.nameFont).foregroundStyle(palette.ink)
            if problem?.field == .name, let problem { ProblemLine(problem: problem) }
            TextField(String(localized: "什么时候用它"), text: Binding(get: { draft.summary }, set: { draft.changed(summary: $0) }), palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Self.summaryFont).foregroundStyle(palette.ink2).lineLimit(1...4)
            if problem?.field == .description, let problem { ProblemLine(problem: problem) }
            if let problem, problem.field == nil { ProblemLine(problem: problem) }
        }
    }

    private static let nameFont = Typography.heading
    private static let summaryFont = Typography.body
}

private struct ProblemLine: View {
    let problem: SkillProblem
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
            FailureMark()
            Text(verbatim: problem.description).foregroundStyle(palette.ink2)
        }
        .font(Typography.meta)
    }
}
