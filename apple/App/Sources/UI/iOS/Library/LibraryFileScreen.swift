#if os(iOS)
import CueStore
import SwiftUI

/// 正文读本地已同步来的那一条（`LibraryFileText`），不向 Mac 要，对上快照的哈希才载入、才跟。不点纸飞机就不发：退出这一页时没发的留在 `Workspace.fileDrafts`，回来接着改。
struct LibraryFileScreen: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var texts: [String: String]?

    var body: some View {
        let library = workspace.library
        let draft = workspace.draft(of: file, in: library)
        VStack(spacing: 0) {
            if let library, let draft {
                LibraryFileTop(file: file, library: library, draft: draft, texts: texts)
                LibraryFileBody(file: file, library: library, draft: draft, texts: texts)
            } else if library?.file(file) != nil {
                Spinner(.small).padding(.top, Spacing.vacant)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.paper.ignoresSafeArea())
        .floatingHeader(.verbatim(workspace.fileTitle(file, in: library)), detail: library?.detail(of: file, draft: draft) ?? Dotted()) { send(draft) }
        .loadingFileDraft(of: file, in: library, texts: $texts) { dismiss() }
    }

    private func send(_ draft: FileDraft?) -> some View {
        Button("发往 Mac", icon: .send) { if let draft { Task { await draft.send() } } }
            .disabled(!(draft?.dirty ?? false) || draft?.state == .saving || draft?.conflicted == true)
    }
}
#endif
