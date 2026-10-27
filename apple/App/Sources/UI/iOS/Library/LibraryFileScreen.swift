#if os(iOS)
import CueEditor
import CueStore
import SwiftUI

/// 一份技能或规则的文件页（手机）：改动攒在这里，顶栏右边的纸飞机"发往 Mac"（有改动才亮），那台写进文件、快照同步回来（`FileDraft`）。
/// 顶上依次是：Mac 上又改过而你也改着时的那一条（`ConflictBar`），同名的分段与"只留这份"、或另写了一份的"合并进来"（`DuplicateBar`、`MergeBar`），
/// 技能的名字与说明两个框；下面是正文。顶栏写它在哪（技能是全局或项目名，规则是名字），第二行写文件名、发着没有。
/// 正文读本地已同步来的那一条（`LibraryFileText`），不向 Mac 要；对上快照的哈希才载入、才跟（`AgentLibrary.arrived`）。
/// 不点纸飞机就不发：退出这一页时没发的留在 `Workspace.fileDraft`，回来接着改。快照里没有这一份了就退回去。
struct LibraryFileScreen: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FileDraft?
    @State private var texts: [String: String]?

    var body: some View {
        let library = workspace.library
        let entry = library?.file(file)
        VStack(spacing: 0) {
            if let library, let draft {
                top(library, draft)
                // 各份正文没到齐时标不出来，照常显示正文
                let blocks = draft.previewing ? merge(library)?.preview(retiring: draft.retire, texts: texts) : nil
                let theme = CueEditorTheme.editor(palette, horizontalInset: 20)
                ZStack {
                    IOSEditorHost(initialText: draft.body, theme: theme, handle: draft.handle,
                                  onChange: { draft.changed(body: $0) }, onError: workspace.fail, editable: blocks == nil)
                    .opacity(blocks == nil ? 1 : 0)
                    if let blocks {
                        MergePreview(blocks: blocks, theme: theme).background(palette.paper)
                    }
                }
            } else if entry != nil {
                // 快照先到了、正文那一条还在路上
                Spinner(.small).padding(.top, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.paper.ignoresSafeArea())
        .floatingHeader(.verbatim(workspace.fileTitle(file, in: library)), detail: detail(entry)) { send }
        .observingLibraryTexts(library?.textPaths(for: file) ?? [], in: library, into: $texts)
        .onChange(of: entry == nil, initial: true) {
            if library != nil, entry == nil { dismiss() }
        }
        .onChange(of: library?.arrived(file, in: texts), initial: true) { _, arrived in
            guard let library, let arrived else { return }
            if let draft { draft.follow(arrived) } else { draft = workspace.fileDraft(file, text: arrived, on: library.hostID) }
        }
    }

    private func merge(_ library: AgentLibrary) -> LibraryTidy? {
        if case .instruction(let kind) = file { library.merge(into: kind) } else { nil }
    }

    /// 正文上面那几块（都没有时不占位置，正文从顶栏下开始）。
    @ViewBuilder private func top(_ library: AgentLibrary, _ draft: FileDraft) -> some View {
        let duplicate: LibraryTidy? = if case .skill(let path) = file { library.duplicate(of: path) } else { nil }
        let merge = merge(library)
        if draft.conflicted || duplicate != nil || merge != nil || isSkill {
            VStack(alignment: .leading, spacing: 12) {
                if draft.conflicted { ConflictBar(draft: draft) }
                if case .skill(let path) = file, let duplicate {
                    DuplicateBar(path: path, tidy: duplicate, library: library)
                } else if let merge {
                    // 有没发的改动时不让合并：合并照 Mac 上此刻的文件做，你的字会变成和它冲突
                    MergeBar(
                        tidy: merge, library: library, draft: draft,
                        ready: merge.preview(retiring: draft.retire, texts: texts) != nil, prepare: draft.dirty ? nil : {})
                }
                if case .skill(let path) = file {
                    SkillFields(draft: draft, problem: library.skill(at: path)?.problem).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var isSkill: Bool { if case .skill = file { true } else { false } }

    /// 顶栏第二行：文件名、发着没有（还没有这个文件时写还没有：写了发往 Mac 就建出来）。
    private func detail(_ entry: (path: String, textPath: String, hash: String?)?) -> Dotted {
        Dotted(entry.map { URL(filePath: $0.textPath).lastPathComponent }, draft?.shownState ?? (entry?.hash == nil ? String(localized: "还没有") : nil))
    }

    private var send: some View {
        Button("发往 Mac", icon: .send) { if let draft { Task { await draft.send() } } }
            .disabled(!(draft?.dirty ?? false) || draft?.state == .saving || draft?.conflicted == true)
            .task(id: draft?.state) {
                guard let draft, draft.state == .saved || draft.state == .followed else { return }
                try? await Task.sleep(for: SaveState.savedDisplay * 2)
                if !Task.isCancelled { draft.settle() }
            }
    }
}
#endif
