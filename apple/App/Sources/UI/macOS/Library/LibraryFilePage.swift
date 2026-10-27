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

/// 一份技能或规则的文件页（Mac）：字在一列里居中，自动存、没有保存钮（`FileDraft`）。页顶一行写它是哪一份、文件在哪、存好没有；
/// 下面是同名的分段与"只留这份"、或另写了一份的"合并进来"（有才有，`DuplicateBar`、`MergeBar`）；技能再是名字与说明两个框，最下面正文。
/// 文件在别处被改了（终端里、别的编辑器、手机发来的）当场跟上，你改着没存上的留着、写出文件变了，由你选换成文件里的或留你的。
/// 快照里没有这一份了（项目解绑了文件夹、去重时这份进了废纸篓）就收起。
private struct LibraryFilePage: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft: FileDraft?
    @State private var previewing = DebugHooks.preset.mergePreview
    @State private var retire: Set<InstructionSource.Origin> = []

    private static let textWidth: CGFloat = 680
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
                ZStack {
                    EditorHost(
                        initialText: draft.body, theme: .editor(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth), handle: draft.handle,
                        onChange: { draft.changed(body: $0) })
                    .opacity(previewing ? 0 : 1)
                    if previewing, let merge = merge(library) {
                        MergePreview(blocks: merge.preview(retiring: retire), font: .system(size: 13.5))
                            .frame(maxWidth: Self.textWidth).padding(.horizontal, Self.inset)
                            .frame(maxWidth: .infinity).background(palette.desk)
                    }
                }
            }
        }
        .padding(.top, Spacing.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk.ignoresSafeArea())
        .onChange(of: entry == nil, initial: true) {
            guard library != nil else { return }
            guard let entry else { workspace.close(.library(file)); return }
            if draft == nil { draft = FileDraft(file, text: entry.text, workspace: workspace) }
        }
        .onChange(of: entry?.text) { draft?.follow(entry?.text) }
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
            MergeBar(tidy: tidy, library: library, previewing: $previewing, retire: $retire) { await draft.leave() }
        }
    }

    /// 页顶一行：图标、它在哪（技能是全局或项目名，规则是名字）、文件在哪、存好没有（或文件变了与"换成文件里的"）。
    private func meta(path: String, library: AgentLibrary, draft: FileDraft) -> some View {
        let shown = if case .skill = file { library.shown(path) + "/SKILL.md" } else { library.shown(path) }
        return HStack(spacing: 8) {
            if case .skill = file { Image(.skill).imageScale(.small) } else { Image(.instruction).imageScale(.small) }
            Text(verbatim: workspace.fileTitle(file, in: library)).foregroundStyle(palette.ink)
            Dotted.inline
            Text(verbatim: shown).lineLimit(1).truncationMode(.middle)
            DraftStatus(draft: draft)
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
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
