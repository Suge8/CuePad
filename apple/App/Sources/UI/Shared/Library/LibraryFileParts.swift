import CueEditor
import CueStore
import SwiftUI

/// 文件页里两端同一份的几块（Mac 的 `LibraryFilePage`、手机的 `LibraryFileScreen` 只管怎么摆）：
/// 顶上那一条——同名的技能是几份的分段加"只留这份"（`DuplicateBar`），内容不同的规则是"<那家> 另写了一份"加"合并进来"（`MergeBar`），
/// 文件在别处改过、你也改着时的那一条（`ConflictBar`）；
/// 技能的 name、description 两个输入框（`SkillFields`，格式哪里不对标在对应的框下）；合并前标出会并进来的段落（`MergePreview`）。

/// 同名的技能：几份的分段（按范围名，换一份就换成那一份的文件页）加"只留这份"（`TidyOrder.keep`，其余进废纸篓；手机发往 Mac）。
struct DuplicateBar: View {
    let path: String
    let tidy: LibraryTidy
    let library: AgentLibrary
    @Environment(Workspace.self) private var workspace
    @State private var working = false

    var body: some View {
        if case .duplicate(_, let copies) = tidy.kind {
            LibraryFileBar {
                Picker(selection: Binding(get: { path }, set: { workspace.openLibrary(.skill($0)) })) {
                    ForEach(copies, id: \.path) { copy in Text(verbatim: workspace.copyName(copy, among: copies)).tag(copy.path) }
                } label: {
                    Text("几份同名的")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 8)
                Button { keep() } label: { TidyLabel(title: "只留这份", working: working) }
                    .buttonStyle(ControlButtonStyle(kind: .primary, compact: true))
                    .disabled(working)
            } consequence: {
                TidyConsequence(kind: .duplicate)
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

/// 内容不同的规则："<那家> 另写了一份"加"合并进来"。两步，按钮说出在哪一步：点"合并进来"先在正文里标出会并进来的段落（`previewing`，`MergePreview`），
/// 这时按钮换成"合并"、旁边"取消"；再点"合并"才做（照那件的合并稿写，`LibraryTidy.merged(retiring:)`，请求带着你看过的那一版，`TidyOrder.base`）。
/// 后果一句贴在按钮下；替换基础提示的那份（Pi 的系统提示、Codex 的自定提示词）有才在标出时给一个勾，勾了才并进来并撤掉它（预览跟着变）。
/// 各份正文没到齐（`ready`）前按不了。两步同一个高：第二行一直占着。
struct MergeBar: View {
    let tidy: LibraryTidy
    let library: AgentLibrary
    @Binding var previewing: Bool
    @Binding var retire: Set<InstructionSource.Origin>
    /// 各份正文都到了、是快照里那一版（`LibraryTidy.preview` 不为 nil）
    let ready: Bool
    /// 合并前先做的事（Mac 写下没存的字）；手机上有没发的改动时为 nil，不让合并
    let prepare: (() async -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var working = false

    var body: some View {
        LibraryFileBar {
            HStack(spacing: 6) {
                ForEach(tidy.writers, id: \.self) { $0.mark.image.foregroundStyle(palette.ink2) }
                Text(verbatim: String(localized: "\(tidy.writers.map(\.name).formatted(.list(type: .and))) 另写了一份"))
                    .font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(2)
            }
            Spacer(minLength: 8)
            if previewing {
                Button("取消") { previewing = false }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
                    .disabled(working)
            }
            Button { merge() } label: { TidyLabel(title: previewing ? "合并" : "合并进来", working: working) }
                .buttonStyle(ControlButtonStyle(kind: previewing ? .primary : .secondary, compact: true))
                .disabled(working || !ready || prepare == nil)
        } consequence: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(tidy.sources.map(\.origin).filter(\.replacesBasePrompt), id: \.self) { origin in
                    Toggle(isOn: Binding(get: { retire.contains(origin) }, set: { if $0 { retire.insert(origin) } else { retire.remove(origin) } })) {
                        Text(verbatim: String(localized: "也合并 \(workspace.replacementName(origin))")).font(Typography.meta).foregroundStyle(palette.ink2)
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    // 一颗选中时着色的小胶囊：手机上没有勾选框
                    .toggleStyle(.button).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    #endif
                    .opacity(previewing ? 1 : 0).disabled(!previewing || working)
                }
                Spacer(minLength: 8)
                TidyConsequence(kind: .merge)
            }
        }
    }

    private func merge() {
        guard previewing else {
            previewing = true
            return
        }
        working = true
        Task {
            await prepare?()
            await workspace.tidy([TidyOrder(tidy: tidy.id, retire: retire, base: tidy.base)], in: library)
            working = false
            previewing = false
        }
    }
}

/// 文件在别处改过、你也改着：一条写出来，给"换成文件里的"（丢下你的）与"留我的"（以文件此刻的为基准写过去盖过它）。
/// 文件此刻的样子还没同步来时只写出来、等它到。手机上说的是那台 Mac。
struct ConflictBar: View {
    let draft: FileDraft
    @Environment(\.palette) private var palette

    var body: some View {
        LibraryFileBar {
            Text(Self.fact).font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(2)
            Spacer(minLength: 8)
            if case .conflict(_?) = draft.state {
                Button(Self.take) { draft.takeFile() }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
                Button("留我的") { Task { await draft.keepMine() } }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
            }
        } consequence: {
            EmptyView()
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

/// 文件页顶上那一条：一行操作，下面一行后果或选项（没有就不占）。Mac 是桌面上的一张纸，手机是纸页上一块桌面色。
struct LibraryFileBar<Content: View, Consequence: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var consequence: Consequence
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) { content }
            consequence
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        #if os(macOS)
        .paper(radius: 12)
        #else
        .background(palette.desk, in: .rect(cornerRadius: 16, style: .continuous))
        #endif
    }
}

/// 合并前的正文：合并稿逐段排开，会并进来的段垫气泡色底、段首一道竖记号（不只靠颜色），其余照常。只看不改。
/// 字、标题（前面淡墨的 #）与这一列的宽同编辑器（`theme`）：从编辑器换过来字不跳大小、不挪位置。
struct MergePreview: View {
    let blocks: [(text: String, incoming: Bool)]
    let theme: CueEditorTheme
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    HStack(alignment: .top, spacing: Self.gap) {
                        Capsule().fill(block.incoming ? palette.ink2 : .clear).frame(width: Self.bar)
                        text(block.text).foregroundStyle(palette.ink).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4).padding(.trailing, 6).padding(.leading, Self.mark)
                    .background(block.incoming ? palette.bubble : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                    // 记号与底挂在字的左边：字与编辑器里的对齐
                    .padding(.leading, -(Self.mark + Self.bar + Self.gap))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(block.incoming ? String(localized: "会并进来") : "")
                }
            }
            .padding(.vertical, 14)
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
            return Text(verbatim: block).font(Font(theme.font as CTFont))
        }
        return Text("\(Text(verbatim: String(marks) + " ").foregroundStyle(palette.ink3))\(Text(verbatim: String(block.dropFirst(marks.count + 1))))")
            .font(Font(theme.headingFont as CTFont))
    }
}

/// 技能的 name 与 description：不写键名，名字框是大号粗体、像这一页的标题，说明在它下面、次一档墨色；空时占位"名字""什么时候用它"。
/// 格式不对的那条标在对应的框下（出错的记号加一句）；说的是放在哪的（`tooDeep`）标在两个框下面。
struct SkillFields: View {
    let draft: FileDraft
    let problem: SkillProblem?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "名字"), text: Binding(get: { draft.name }, set: { draft.changed(name: $0) }), palette: palette)
                .textFieldStyle(.plain).font(Self.nameFont).foregroundStyle(palette.ink)
            if problem?.field == .name, let problem { ProblemLine(problem: problem) }
            TextField(String(localized: "什么时候用它"), text: Binding(get: { draft.summary }, set: { draft.changed(summary: $0) }), palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Self.summaryFont).foregroundStyle(palette.ink2).lineLimit(1...4)
            if problem?.field == .description, let problem { ProblemLine(problem: problem) }
            if let problem, problem.field == nil { ProblemLine(problem: problem) }
        }
    }

    #if os(macOS)
    private static let nameFont = Typography.heading
    private static let summaryFont = Typography.body
    #else
    private static let nameFont = Font.title2.weight(.bold)
    private static let summaryFont = Font.body
    #endif
}

/// 格式哪里不对：出错的记号加一句。
private struct ProblemLine: View {
    let problem: SkillProblem
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            FailureMark()
            Text(verbatim: problem.description).foregroundStyle(palette.ink2)
        }
        .font(Typography.meta)
    }
}
