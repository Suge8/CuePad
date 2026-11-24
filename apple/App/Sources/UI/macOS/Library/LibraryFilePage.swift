#if os(macOS)
import CueStore
import SwiftUI

struct LibraryFilePage: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var texts: [String: String]?

    var body: some View {
        let library = workspace.library
        let draft = workspace.draft(of: file, in: library)
        ZStack {
            if let library, library.file(file) != nil, let draft {
                LibraryFileBody(file: file, library: library, draft: draft, texts: texts)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk.ignoresSafeArea())
        .loadingFileDraft(of: file, in: library, texts: $texts)
        .task(id: draft != nil) {
            await NextFrame.wait()
            draft?.handle.focus()
        }
        .onDisappear { if let draft { Task { await draft.leave() } } }
    }
}
#endif
