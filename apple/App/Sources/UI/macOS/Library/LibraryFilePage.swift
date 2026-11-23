#if os(macOS)
import CueStore
import SwiftUI

struct LibraryFileLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if workspace.isLibraryReady, let file = workspace.openLibraryFile {
                LibraryFilePage(file: file).safeAreaPadding(.top, Chrome.band)
                    .overlay(alignment: .top) { LibraryFileHead(file: file) }
                    .id(file).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: workspace.openLibraryFile)
    }
}

private struct LibraryFilePage: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var texts: [String: String]?

    var body: some View {
        let library = workspace.library
        let draft = workspace.draft(of: file, in: library)
        VStack(spacing: Spacing.block) {
            if let library, library.file(file) != nil, let draft {
                LibraryFileTop(file: file, library: library, draft: draft, texts: texts)
                LibraryFileBody(file: file, library: library, draft: draft, texts: texts)
            }
        }
        .padding(.top, Spacing.pageTop)
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
