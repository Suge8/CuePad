#if os(macOS)
import CueEditor
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

/// 一份技能或规则的文件页（Mac）：字在一列里居中（同技能与规则页那一列），自动存、没有保存钮（`FileDraft`）。它是哪一份、存好没有在工具栏中间
/// （`OverlayHeader`：标题同手机，技能是全局或项目名、规则是名字；次要一行是文件名与存好没有；完整路径悬停看），页里不另写。
/// 顶上是文件在别处改过的那一条、同名的分段与"只留这份"、或另写了一份的"合并进来"（有才有，`ConflictBar`、`DuplicateBar`、`MergeBar`）；技能再是名字与说明两个框，最下面正文。
/// 正文读库里那台写下的那一条（`LibraryFileText`），对上快照的哈希才载入、才跟（`AgentLibrary.arrived`）。
/// 文件在别处被改了（终端里、别的编辑器、手机发来的）当场跟上，你改着没存上的留着、顶上一条写出文件变了，由你选换成文件里的或留你的。
/// 快照里没有这一份了（项目解绑了文件夹、去重时这份进了废纸篓）就收起。
private struct LibraryFilePage: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft: FileDraft?
    @State private var texts: [String: String]?

    private static let textWidth: CGFloat = LibraryLayout.column
    private static let inset: CGFloat = 24

    var body: some View {
        let library = workspace.library
        let entry = library?.file(file)
        VStack(spacing: 14) {
            if let library, entry != nil, let draft {
                Group {
                    if draft.conflicted { ConflictBar(draft: draft) }
                    bar(library, draft)
                    if case .skill(let path) = file { SkillFields(draft: draft, problem: library.skill(at: path)?.problem) }
                }
                .frame(maxWidth: Self.textWidth, alignment: .leading).padding(.horizontal, Self.inset)
                // 各份正文没到齐时标不出来，照常显示正文
                let blocks = draft.previewing ? merge(library)?.preview(retiring: draft.retire, texts: texts) : nil
                let theme = CueEditorTheme.editor(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth)
                ZStack {
                    EditorHost(
                        initialText: draft.body, theme: theme, handle: draft.handle,
                        onChange: { draft.changed(body: $0) }, editable: blocks == nil)
                    .opacity(blocks == nil ? 1 : 0)
                    if let blocks {
                        MergePreview(blocks: blocks, theme: theme).background(palette.desk)
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
            guard let library, let arrived else { return }
            if let draft { draft.follow(arrived) } else { draft = workspace.fileDraft(file, text: arrived, on: library.hostID) }
        }
        .task(id: draft != nil) {
            await NextFrame.wait()
            draft?.handle.focus()
        }
        .overlayHeader(header(library, entry: entry), in: workspace)
        .task(id: draft?.state) {
            guard let draft, draft.state == .saved || draft.state == .followed else { return }
            try? await Task.sleep(for: SaveState.savedDisplay * 2)
            if !Task.isCancelled { draft.settle() }
        }
        .onDisappear { if let draft { Task { await draft.leave() } } }
    }

    /// 工具栏中间那一块：标题同手机（技能是全局或项目名，规则是名字），次要一行是文件名与存好没有（还没有这个文件时写还没有：写了就建出来）；完整路径悬停看（多是一长串家目录里的点目录）。
    private func header(_ library: AgentLibrary?, entry: (path: String, textPath: String, hash: String?)?) -> OverlayHeader.Content {
        let name = entry.map { URL(filePath: $0.textPath).lastPathComponent }
        return OverlayHeader.Content(
            page: .library(file), title: workspace.fileTitle(file, in: library),
            detail: Dotted(name, draft?.shownState ?? (entry?.hash == nil ? String(localized: "还没有") : nil)),
            failed: draft?.state == .failed, help: entry.flatMap { library?.shown($0.textPath) },
            widest: Dotted(name, FileDraft.longestShownState))
    }

    private func merge(_ library: AgentLibrary) -> LibraryTidy? {
        if case .instruction(let kind) = file { library.merge(into: kind) } else { nil }
    }

    @ViewBuilder private func bar(_ library: AgentLibrary, _ draft: FileDraft) -> some View {
        if case .skill(let path) = file, let tidy = library.duplicate(of: path) {
            DuplicateBar(path: path, tidy: tidy, library: library)
        } else if let tidy = merge(library) {
            MergeBar(tidy: tidy, library: library, draft: draft, ready: tidy.preview(retiring: draft.retire, texts: texts) != nil) {
                await draft.leave()
            }
        }
    }
}
#endif
