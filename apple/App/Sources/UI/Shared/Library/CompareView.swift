import CueStore
import SwiftUI

/// 比一比（要整理里同名的技能、各写一份的全局规则、项目里另一份 CLAUDE.md）：几份原文并排，每份一张纸——头上写是谁的哪一份，
/// 只有这一份有的段落垫一层牛皮纸色（差异不用状态色：不是出了错，只是"这里不一样"）。Mac 上几列并排、各自滚；手机上左右翻（露出下一张的边）。
/// 说明合成成一份（`LibraryTidy.merged(retiring:)`，按段取并集），各家改成读它，原来的进废纸篓；替换基础提示的两份（Pi 的系统提示、Codex 的自定提示词）
/// 只作比对，勾了"合进去，撤掉这份"才并进来并撤掉（`TidyOrder.retire`），不勾就原样留着。同名的技能每份底下一颗"留这份"，其余进废纸篓。
/// 那件不在了就回技能与说明页（整理好了、在别处整理过）；合成了说明的，`Workspace.tidy` 换成合成出的那份说明的编辑页。结果与撤销在提示里，没成留在这里。
struct CompareView: View {
    let tidyID: String
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var retire: Set<InstructionSource.Origin> = []
    @State private var working = false

    var body: some View {
        if let library = workspace.library {
            if let tidy = library.tidies.first(where: { $0.id == tidyID }) {
                content(tidy, library)
            } else {
                Color.clear.onAppear(perform: close)
            }
        }
    }

    @ViewBuilder private func content(_ tidy: LibraryTidy, _ library: AgentLibrary) -> some View {
        let pages = Self.pages(of: tidy, workspace: workspace, library: library)
        VStack(spacing: 14) {
            columns(pages, tidy: tidy, library: library)
            if tidy.action != .compare || !tidy.sources.isEmpty { bar(tidy, library) }
        }
    }

    // MARK: 几份

    struct Page: Identifiable {
        let id: String
        let mark: BrandMark?
        let icon: Icon?
        let name: String
        let place: String
        let modified: Date?
        let blocks: [(text: String, differs: Bool)]
        /// 替换基础提示的那份（合成时可选一并撤掉）
        let optional: InstructionSource.Origin?
        /// 同名技能的那份（"留这份"）
        let keep: String?
    }

    static func pages(of tidy: LibraryTidy, workspace: Workspace, library: AgentLibrary) -> [Page] {
        var texts: [String?] = []
        var heads: [(String, BrandMark?, Icon?, String, String, Date?, InstructionSource.Origin?, String?)] = []
        switch tidy.kind {
        case .duplicate(_, let copies):
            for copy in copies {
                texts.append(copy.text)
                heads.append((copy.skill.path, nil, .skill, workspace.scopeName(copy.skill.scope), library.shown(copy.skill.path), copy.modifiedAt, nil, copy.skill.path))
            }
        case .globalInstructions(let sources), .projectClaude(_, let sources):
            let project: UUID? = if case .projectClaude(let id, _) = tidy.kind { id } else { nil }
            for source in sources {
                texts.append(source.text)
                let mark = source.origin.agent?.mark
                heads.append((source.path, mark, mark == nil ? .instruction : nil, workspace.sourceName(source.origin, project: project),
                              library.shown(source.path), source.modifiedAt, source.origin.replacesBasePrompt ? source.origin : nil, nil))
            }
        default: return []
        }
        let keys = texts.map { Set(InstructionMerge.blocks(of: $0 ?? "").map(InstructionMerge.normalized)) }
        return heads.enumerated().map { index, head in
            let others = keys.enumerated().filter { $0.offset != index && texts[$0.offset] != nil }.map(\.element)
            let blocks = InstructionMerge.blocks(of: texts[index] ?? "").map { block in
                let key = InstructionMerge.normalized(block)
                return (block, !others.isEmpty && !others.contains { $0.contains(key) })
            }
            return Page(id: head.0, mark: head.1, icon: head.2, name: head.3, place: head.4, modified: head.5, blocks: blocks, optional: head.6, keep: head.7)
        }
    }

    @ViewBuilder private func columns(_ pages: [Page], tidy: LibraryTidy, library: AgentLibrary) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 16) {
            ForEach(pages) { sheet($0, tidy: tidy, library: library) }
        }
        #else
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(pages) { sheet($0, tidy: tidy, library: library).containerRelativeFrame(.horizontal) { width, _ in width - 44 } }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .safeAreaPadding(.horizontal, 16)
        .scrollIndicators(.hidden)
        #endif
    }

    /// 一份：头上是谁的、在哪、什么时候改的；正文按段，只有它有的垫底；可选撤掉的头下一个勾；同名技能底下"留这份"。
    private func sheet(_ page: Page, tidy: LibraryTidy, library: AgentLibrary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 名字占满一行宽、写不下折成两行（各列都留两行的高，下面的正文各列对齐），不截；在哪、什么时候改的在下一行
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let mark = page.mark { mark.image } else if let icon = page.icon { Image(icon) }
                Text(verbatim: page.name).font(Typography.bodyStrong).lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(palette.ink)
            HStack(spacing: 6) {
                Text(verbatim: page.place).lineLimit(1).truncationMode(.middle)
                if let modified = page.modified { Text(verbatim: DateLabel.short(modified)).fixedSize() }
            }
            .font(Typography.meta).foregroundStyle(palette.ink3).padding(.top, 2)
            if let origin = page.optional {
                Toggle(isOn: Binding(get: { retire.contains(origin) }, set: { if $0 { retire.insert(origin) } else { retire.remove(origin) } })) {
                    Text("合进去，撤掉这份").font(Typography.meta).foregroundStyle(palette.ink2)
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if page.blocks.isEmpty { Text("还没有").font(Typography.secondary).foregroundStyle(palette.ink3) }
                    ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, block in
                        Text(verbatim: block.text).font(Self.textFont).foregroundStyle(palette.ink).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(block.differs ? palette.bubble : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                            .padding(.horizontal, -6)
                    }
                }
                .padding(.vertical, 14)
                .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
            if let keep = page.keep {
                Button { run(tidy, library, keep: keep) } label: {
                    Text("留这份").frame(maxWidth: .infinity)
                }
                .buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
                .disabled(working)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .paper(radius: LibraryPaper<EmptyView>.radius)
    }

    /// 底下那一条：合成会做什么（各家改成读它、原来的进废纸篓），右边"合成"。手机上带纸飞机：是发往 Mac 去做的。
    private func bar(_ tidy: LibraryTidy, _ library: AgentLibrary) -> some View {
        HStack(spacing: 12) {
            Image(.instruction).foregroundStyle(palette.ink2)
            Text(Self.outcome(tidy)).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { run(tidy, library, keep: nil) } label: {
                HStack(spacing: 5) {
                    #if os(iOS)
                    Image(.send).imageScale(.small)
                    #endif
                    Text("合成")
                }
                .opacity(working ? 0 : 1)
                .overlay { if working { Spinner(.mini) } }
            }
            .buttonStyle(ControlButtonStyle(kind: .primary))
            .disabled(working)
        }
        .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
        .glass(in: .capsule)
    }

    private static func outcome(_ tidy: LibraryTidy) -> String {
        if case .projectClaude = tidy.kind { return String(localized: "合进 AGENTS.md，Claude Code 改读它；CLAUDE.md 进废纸篓") }
        return String(localized: "合成一份全局说明，各家改成读它；原来的进废纸篓")
    }

    private func run(_ tidy: LibraryTidy, _ library: AgentLibrary, keep: String?) {
        working = true
        let order = TidyOrder(tidy: tidy.id, keep: keep, retire: keep == nil ? retire : [])
        Task {
            await workspace.tidy([order], in: library)
            working = false
        }
    }

    #if os(macOS)
    private static let textFont = Font.system(size: 13.5)
    #else
    private static let textFont = Font.subheadline
    #endif
}
