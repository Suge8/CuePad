#if os(macOS)
import CueStore
import SwiftUI

/// 打开时先在看不见时挂好（编辑器要接过键盘），下一帧再淡入：淡入的每一帧只剩改透明度。
struct LibraryFileLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if workspace.isLibraryReady, let file = workspace.openLibraryFile {
                LibraryFilePage(file: file).id(file).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: workspace.openLibraryFile)
    }
}

/// 正文读库里那台写下的那一条（`LibraryFileText`），对上快照的哈希才载入、才跟。
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
        .overlayHeader(header(library, draft), in: workspace)
        .onDisappear { if let draft { Task { await draft.leave() } } }
    }

    private func header(_ library: AgentLibrary?, _ draft: FileDraft?) -> OverlayHeader.Content {
        let entry = library?.file(file)
        return OverlayHeader.Content(
            page: .library(file), title: workspace.fileTitle(file, in: library),
            detail: library?.detail(of: file, draft: draft) ?? Dotted(),
            failed: draft?.state == .failed, help: entry.flatMap { library?.shown($0.textPath) },
            widest: Dotted(library?.fileName(file), FileDraft.longestShownState))
    }
}
#endif
