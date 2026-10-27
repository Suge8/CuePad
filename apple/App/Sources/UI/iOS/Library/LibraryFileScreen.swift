#if os(iOS)
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
        VStack(spacing: 0) {
            if let library, let draft {
                LibraryFileTop(file: file, library: library, draft: draft, texts: texts)
                LibraryFileBody(file: file, library: library, draft: draft, texts: texts)
            } else if library?.file(file) != nil {
                // 快照先到了、正文那一条还在路上
                Spinner(.small).padding(.top, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.paper.ignoresSafeArea())
        .floatingHeader(.verbatim(workspace.fileTitle(file, in: library)), detail: library?.detail(of: file, draft: draft) ?? Dotted()) { send }
        .loadingFileDraft($draft, of: file, in: library, texts: $texts) { dismiss() }
    }

    private var send: some View {
        Button("发往 Mac", icon: .send) { if let draft { Task { await draft.send() } } }
            .disabled(!(draft?.dirty ?? false) || draft?.state == .saving || draft?.conflicted == true)
    }
}
#endif
