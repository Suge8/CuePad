#if os(iOS)
import CueStore
import SwiftUI

/// 一份技能或规则的文件页（手机）：改动攒在这里，顶栏右边的纸飞机"发往 Mac"（有改动才亮），那台写进文件、快照同步回来（`FileDraft`）。
/// 顶上依次是：Mac 上又改过而你也改着时的那一条（换成 Mac 上的、留我的），同名的分段与"只留这份"、或另写了一份的"合并进来"（`DuplicateBar`、`MergeBar`），
/// 技能的名字与说明两个框；下面是正文。顶栏写它在哪（技能是全局或项目名，规则是名字），第二行写文件名、发着没有。
/// 不点纸飞机就不发：退出这一页时没发的留在 `Workspace.fileDraft`，回来接着改。快照里没有这一份了就退回去。
struct LibraryFileScreen: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FileDraft?
    @State private var previewing = DebugHooks.preset.mergePreview
    @State private var retire: Set<InstructionSource.Origin> = []

    var body: some View {
        let library = workspace.library
        let entry = library?.file(file)
        VStack(spacing: 0) {
            if let library, let draft {
                top(library, draft)
                ZStack {
                    IOSEditorHost(initialText: draft.body, theme: .editor(palette, horizontalInset: 20), handle: draft.handle,
                                  onChange: { draft.changed(body: $0) }, onError: workspace.fail)
                    .opacity(previewing ? 0 : 1)
                    if previewing, let merge = merge(library) {
                        MergePreview(blocks: merge.preview(retiring: retire), font: .body).padding(.horizontal, 16).background(palette.paper)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.paper.ignoresSafeArea())
        .floatingHeader(.verbatim(workspace.fileTitle(file, in: library)), detail: detail(entry?.path)) { send }
        .onChange(of: entry == nil, initial: true) {
            guard let library else { return }
            guard let entry else { dismiss(); return }
            if draft == nil { draft = workspace.fileDraft(file, text: entry.text, on: library.hostID) }
        }
        .onChange(of: entry?.text) { draft?.follow(entry?.text) }
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
                if case .conflict(let file) = draft.state { conflict(draft, file: file) }
                if case .skill(let path) = file, let duplicate {
                    DuplicateBar(path: path, tidy: duplicate, library: library)
                } else if let merge {
                    // 有没发的改动时不让合并：合并照 Mac 上此刻的文件做，你的字会变成和它冲突
                    MergeBar(tidy: merge, library: library, previewing: $previewing, retire: $retire, prepare: draft.dirty ? nil : {})
                }
                if case .skill(let path) = file {
                    SkillFields(draft: draft, problem: library.skill(at: path)?.problem).padding(.horizontal, 4)
                    Divider()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var isSkill: Bool { if case .skill = file { true } else { false } }

    /// 顶栏第二行：文件名、发着没有。
    private func detail(_ path: String?) -> Dotted {
        let name = path.map { isSkill ? "SKILL.md" : ($0 as NSString).lastPathComponent } ?? ""
        let state: String? = switch draft?.state {
        case .saving: String(localized: "正在发往 Mac…")
        case .saved: String(localized: "Mac 上已写好")
        case .followed: String(localized: "Mac 上改过，已跟上")
        case .failed: String(localized: "没发出去")
        default: draft?.dirty == true ? String(localized: "有改动没发") : nil
        }
        return Dotted(name, state)
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

    /// Mac 上改过、你也改着：一条写出来，给"换成 Mac 上的"（丢下你的）与"留我的"（以 Mac 上此刻的为基准发过去盖过它）。
    private func conflict(_ draft: FileDraft, file: String?) -> some View {
        HStack(spacing: 10) {
            Text("Mac 上改过了，你改的还没发").font(.footnote).foregroundStyle(palette.ink)
            Spacer(minLength: 8)
            if file != nil {
                Button("换成 Mac 上的") { draft.takeFile() }.font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
                Button("留我的") { Task { await draft.keepMine() } }.font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(palette.bubble, in: .rect(cornerRadius: 16, style: .continuous))
    }
}
#endif
