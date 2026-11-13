import CueEditor
import CueStore
import SwiftUI

struct LibraryFileTop: View {
    let file: LibraryFile
    let library: AgentLibrary
    let draft: FileDraft
    let texts: [String: String]?

    var body: some View {
        let skill: String? = if case .skill(let path) = file { path } else { nil }
        let duplicate = library.duplicate(for: file)
        let merge = library.merge(for: file)
        // 另写了一份的先合并进来，不拿底稿盖过它
        let starter = file == .instruction(.global) && draft.blank && merge == nil
        if draft.conflicted || duplicate != nil || merge != nil || starter || skill != nil {
            VStack(alignment: .leading, spacing: Self.gap) {
                if draft.conflicted { ConflictBar(draft: draft) }
                if let skill, let duplicate {
                    DuplicateBar(path: skill, tidy: duplicate, library: library)
                } else if let merge {
                    MergeBar(tidy: merge, library: library, draft: draft, texts: texts)
                } else if starter {
                    StarterBar(draft: draft)
                }
                if let skill {
                    SkillFields(draft: draft, problem: library.skill(at: skill)?.problem)
                }
            }
            #if os(macOS)
            .frame(maxWidth: LibraryLayout.column, alignment: .leading).padding(.horizontal, LibraryLayout.textInset)
            #else
            .padding(.horizontal, LibraryLayout.textInset).padding(.vertical, Spacing.item)
            #endif
        }
    }

    #if os(macOS)
    private static let gap = Spacing.block
    #else
    private static let gap = Spacing.group
    #endif
}

/// 文件页下半：正文编辑器；合并前标出时换成合并稿、编辑器交出键盘（`FileDraft.previewing`）。各份正文没到齐时标不出来，照常显示正文。
struct LibraryFileBody: View {
    let file: LibraryFile
    let library: AgentLibrary
    let draft: FileDraft
    let texts: [String: String]?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let blocks = draft.previewing ? library.merge(for: file)?.preview(retiring: draft.retire, texts: texts) : nil
        let theme = Self.theme(palette)
        ZStack {
            #if os(macOS)
            EditorHost(initialText: draft.body, theme: theme, handle: draft.handle, onChange: { draft.changed(body: $0) },
                       onError: workspace.fail, editable: blocks == nil)
                .opacity(blocks == nil ? 1 : 0)
            #else
            IOSEditorHost(initialText: draft.body, theme: theme, handle: draft.handle, onChange: { draft.changed(body: $0) },
                          onError: workspace.fail, editable: blocks == nil)
                .opacity(blocks == nil ? 1 : 0)
            #endif
            if let blocks {
                MergePreview(blocks: blocks, theme: theme).background(Self.page(palette))
            }
        }
    }

    #if os(macOS)
    private static func theme(_ palette: Palette) -> CueEditorTheme {
        .editor(palette, horizontalInset: LibraryLayout.textInset, maxTextWidth: LibraryLayout.column)
    }
    private static func page(_ palette: Palette) -> Color { palette.desk }
    #else
    private static func theme(_ palette: Palette) -> CueEditorTheme { .editor(palette, horizontalInset: LibraryLayout.textInset) }
    private static func page(_ palette: Palette) -> Color { palette.paper }
    #endif
}

extension View {
    func loadingFileDraft(
        of file: LibraryFile, in library: AgentLibrary?, texts: Binding<[String: String]?>
    ) -> some View {
        modifier(FileDraftLoading(file: file, library: library, texts: texts))
    }
}

private struct FileDraftLoading: ViewModifier {
    let file: LibraryFile
    let library: AgentLibrary?
    @Binding var texts: [String: String]?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let gone = library != nil && library?.file(file) == nil
        let draft = workspace.draft(of: file, in: library)
        content
            .observingLibraryTexts(library?.textPaths(for: file) ?? [], in: library, into: $texts)
            .onChange(of: gone, initial: true) { if gone { workspace.leave(.libraryFile(file)) } }
            .onChange(of: library?.arrived(file, in: texts), initial: true) { _, arrived in
                guard let library, let arrived else { return }
                _ = workspace.fileDraft(file, text: arrived, on: library.hostID)
            }
            .task(id: draft?.state) { await draft?.settleSoon() }
    }
}
