import CueEditor
import CueStore
import SwiftUI

/// 文件页上半：文件在别处改过的那一条、同名的分段加"只留这份"或另写了一份的"合并进来"、技能的名字与说明两个框；都没有时不占位置，
/// 正文从页顶下开始。两端同一份，只有摆法随端：Mac 与正文同一列（`LibraryLayout.column`），手机是铺满的一块。
struct LibraryFileTop: View {
    let file: LibraryFile
    let library: AgentLibrary
    let draft: FileDraft
    let texts: [String: String]?

    var body: some View {
        let skill: String? = if case .skill(let path) = file { path } else { nil }
        let duplicate = library.duplicate(for: file)
        let merge = library.merge(for: file)
        if draft.conflicted || duplicate != nil || merge != nil || skill != nil {
            VStack(alignment: .leading, spacing: Self.gap) {
                if draft.conflicted { ConflictBar(draft: draft) }
                if let skill, let duplicate {
                    DuplicateBar(path: skill, tidy: duplicate, library: library)
                } else if let merge {
                    MergeBar(tidy: merge, library: library, draft: draft, texts: texts)
                }
                if let skill {
                    SkillFields(draft: draft, problem: library.skill(at: skill)?.problem).padding(.horizontal, Self.fieldsInset)
                }
            }
            #if os(macOS)
            .frame(maxWidth: LibraryLayout.column, alignment: .leading).padding(.horizontal, LibraryLayout.textInset)
            #else
            .padding(.horizontal, 16).padding(.vertical, 8)
            #endif
        }
    }

    #if os(macOS)
    private static let gap: CGFloat = 14
    private static let fieldsInset: CGFloat = 0
    #else
    private static let gap: CGFloat = 12
    private static let fieldsInset: CGFloat = 4
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

    // 底色同各自的页（Mac 桌面色、手机纸色）
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
    /// 文件页挂上与跟着文件走（两端同一份）：读这一份的各份正文（`observingLibraryTexts`），对上快照的哈希就载入改动（`Workspace.fileDraft`），
    /// 之后正文变了就跟（`FileDraft.follow`）；快照里没有这一份了调 `onGone`；"已保存"、"已跟上"亮一会儿就收（`FileDraft.settleSoon`）。
    func loadingFileDraft(
        of file: LibraryFile, in library: AgentLibrary?, texts: Binding<[String: String]?>, onGone: @escaping () -> Void
    ) -> some View {
        modifier(FileDraftLoading(file: file, library: library, texts: texts, onGone: onGone))
    }
}

private struct FileDraftLoading: ViewModifier {
    let file: LibraryFile
    let library: AgentLibrary?
    @Binding var texts: [String: String]?
    let onGone: () -> Void
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let gone = library != nil && library?.file(file) == nil
        let draft = workspace.draft(of: file, in: library)
        content
            .observingLibraryTexts(library?.textPaths(for: file) ?? [], in: library, into: $texts)
            .onChange(of: gone, initial: true) { if gone { onGone() } }
            .onChange(of: library?.arrived(file, in: texts), initial: true) { _, arrived in
                guard let library, let arrived else { return }
                _ = workspace.fileDraft(file, text: arrived, on: library.hostID)
            }
            .task(id: draft?.state) { await draft?.settleSoon() }
    }
}
