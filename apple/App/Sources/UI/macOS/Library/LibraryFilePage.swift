#if os(macOS)
import CueStore
import SwiftUI

/// 技能与规则的文件页，盖在当前页上（同灵感的编辑页：铺满内容区、与页面同底色，开合原地淡入淡出，左上"收起"、Esc 关）。
/// 打开时先在看不见时挂好（编辑器要接过键盘），下一帧再淡入：淡入的每一帧只剩改透明度。
struct LibraryFileLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if workspace.isLibraryReady, let file = workspace.openLibraryFile {
                LibraryFilePage(file: file).id(file).transition(.opacity)
            }
        }
        .animation(HandOff.quick, value: workspace.openLibraryFile)
    }
}

/// 一份技能或规则的文件页（Mac）：字在一列里居中（同技能与规则页那一列），自动存、没有保存钮（`FileDraft`）。页顶一行写它是哪一份、存好没有；
/// 下面是同名的分段与"只留这份"、或另写了一份的"合并进来"（有才有，`DuplicateBar`、`MergeBar`）；技能再是名字与说明两个框，最下面正文。
/// 正文读库里那台写下的那一条（`LibraryFileText`），对上快照的哈希才载入、才跟（`AgentLibrary.arrived`）。
/// 文件在别处被改了（终端里、别的编辑器、手机发来的）当场跟上，你改着没存上的留着、写出文件变了，由你选换成文件里的或留你的。
/// 快照里没有这一份了（项目解绑了文件夹、去重时这份进了废纸篓）就收起。
private struct LibraryFilePage: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft: FileDraft?
    @State private var texts: [String: String]?
    @State private var previewing = DebugHooks.preset.mergePreview
    @State private var retire: Set<InstructionSource.Origin> = []

    private static let textWidth: CGFloat = LibraryLayout.column
    /// 页顶那一行按"换成文件里的""留我的"两颗钮的高留着：冲突时出现不把下面推下去
    private static let metaHeight: CGFloat = 22
    private static let inset: CGFloat = 24

    var body: some View {
        let library = workspace.library
        let entry = library?.file(file)
        VStack(spacing: 14) {
            if let library, let entry, let draft {
                Group {
                    meta(path: entry.path, library: library, draft: draft)
                    bar(library, draft)
                    if case .skill(let path) = file { SkillFields(draft: draft, problem: library.skill(at: path)?.problem) }
                }
                .frame(maxWidth: Self.textWidth, alignment: .leading).padding(.horizontal, Self.inset)
                // 各份正文没到齐时标不出来，照常显示正文
                let blocks = previewing ? merge(library)?.preview(retiring: retire, texts: texts) : nil
                ZStack {
                    EditorHost(
                        initialText: draft.body, theme: .editor(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth), handle: draft.handle,
                        onChange: { draft.changed(body: $0) })
                    .opacity(blocks == nil ? 1 : 0)
                    if let blocks {
                        MergePreview(blocks: blocks, font: .system(size: 13.5))
                            .frame(maxWidth: Self.textWidth).padding(.horizontal, Self.inset)
                            .frame(maxWidth: .infinity).background(palette.desk)
                    }
                }
            }
        }
        .padding(.top, Spacing.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk.ignoresSafeArea())
        .observingLibraryTexts(library?.textPaths(for: file) ?? [], in: library, into: $texts)
        .onChange(of: entry == nil, initial: true) {
            if library != nil, entry == nil { workspace.close(.library(file)) }
        }
        .onChange(of: library?.arrived(file, in: texts), initial: true) { _, arrived in
            guard let arrived else { return }
            if let draft { draft.follow(arrived) } else { draft = FileDraft(file, text: arrived, workspace: workspace) }
        }
        .task(id: draft != nil) {
            await NextFrame.wait()
            draft?.handle.focus()
        }
        .onDisappear { if let draft { Task { await draft.leave() } } }
    }

    private func merge(_ library: AgentLibrary) -> LibraryTidy? {
        if case .instruction(let kind) = file { library.merge(into: kind) } else { nil }
    }

    @ViewBuilder private func bar(_ library: AgentLibrary, _ draft: FileDraft) -> some View {
        if case .skill(let path) = file, let tidy = library.duplicate(of: path) {
            DuplicateBar(path: path, tidy: tidy, library: library)
        } else if let tidy = merge(library) {
            MergeBar(tidy: tidy, library: library, previewing: $previewing, retire: $retire, ready: tidy.preview(retiring: retire, texts: texts) != nil) {
                await draft.leave()
            }
        }
    }

    /// 页顶一行：图标、它在哪（技能是全局或项目名，规则是名字；同名的有几份时下面的分段已经写了，不重复）、存好没有（或文件变了与"换成文件里的"）。
    /// 完整路径不占这一行（多是一长串家目录里的点目录，没人读），悬停在名字上看；技能要去访达在清单那一行的右键菜单里。
    private func meta(path: String, library: AgentLibrary, draft: FileDraft) -> some View {
        let shown = if case .skill = file { library.shown(path) + "/SKILL.md" } else { library.shown(path) }
        let duplicated = if case .skill(let path) = file { library.duplicate(of: path) != nil } else { false }
        return HStack(spacing: 8) {
            if !duplicated {
                HStack(spacing: 6) {
                    if case .skill = file { Image(.skill).imageScale(.small) } else { Image(.instruction).imageScale(.small) }
                    Text(verbatim: workspace.fileTitle(file, in: library)).foregroundStyle(palette.ink)
                }
                .help(shown)
            }
            DraftStatus(draft: draft)
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
        .frame(minHeight: Self.metaHeight, alignment: .leading)
    }
}

/// 存好没有：存的时候"保存中…"，存好"已保存"亮一会儿；在别处改过且已跟上写"在别处改过，已跟上"；你改着而文件变了写出来、给"换成文件里的"与"留我的"。
struct DraftStatus: View {
    let draft: FileDraft
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch draft.state {
            case .idle: EmptyView()
            case .saving: Text(SaveState.saving.text ?? "")
            case .saved: Text(SaveState.saved.text ?? "")
            case .followed: Text("在别处改过，已跟上").foregroundStyle(palette.ink2)
            case .failed: Text(SaveState.failed.text ?? "").foregroundStyle(palette.failure)
            case .conflict(let file):
                HStack(spacing: 8) {
                    Text("文件在别处改过了").foregroundStyle(palette.ink)
                    if file != nil {
                        Button("换成文件里的") { draft.takeFile() }.buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink)
                        Button("留我的") { Task { await draft.keepMine() } }.buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink)
                    }
                }
            }
        }
        .transition(.opacity)
        .animation(HandOff.quick, value: draft.state)
        .task(id: draft.state) {
            guard draft.state == .saved || draft.state == .followed else { return }
            try? await Task.sleep(for: SaveState.savedDisplay * 2)
            if !Task.isCancelled { draft.settle() }
        }
    }
}
#endif
