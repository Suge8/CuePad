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
        .animation(Motion.fade, value: workspace.openLibraryFile)
    }
}

/// 一份技能或规则的文件页（Mac）：字在一列里居中（同技能与规则页那一列），自动存、没有保存钮（`FileDraft`）。它是哪一份、存好没有在工具栏中间
/// （`OverlayHeader`：标题同手机，技能是全局或项目名、规则是名字；次要一行是文件名与存好没有；完整路径悬停看），页里不另写。
/// 顶上是文件在别处改过的那一条、同名的分段与"只留这份"、或另写了一份的"合并进来"（有才有，`ConflictBar`、`DuplicateBar`、`MergeBar`）；技能再是名字与说明两个框，最下面正文。
/// 正文读库里那台写下的那一条（`LibraryFileText`），对上快照的哈希才载入、才跟（`AgentLibrary.arrived`）。
/// 文件在别处被改了（终端里、别的编辑器、手机发来的）当场跟上，你改着没存上的留着、顶上一条写出文件变了，由你选换成文件里的或留你的。
/// 快照里没有这一份了（项目解绑了文件夹、去重时这份进了废纸篓）就收起。
private struct LibraryFilePage: View {
    let file: LibraryFile
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft: FileDraft?
    @State private var texts: [String: String]?

    var body: some View {
        let library = workspace.library
        VStack(spacing: 14) {
            if let library, library.file(file) != nil, let draft {
                LibraryFileTop(file: file, library: library, draft: draft, texts: texts)
                LibraryFileBody(file: file, library: library, draft: draft, texts: texts)
            }
        }
        .padding(.top, Spacing.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk.ignoresSafeArea())
        .loadingFileDraft($draft, of: file, in: library, texts: $texts) { workspace.close(.library(file)) }
        .task(id: draft != nil) {
            await NextFrame.wait()
            draft?.handle.focus()
        }
        .overlayHeader(header(library), in: workspace)
        .onDisappear { if let draft { Task { await draft.leave() } } }
    }

    /// 工具栏中间那一块：标题同手机（技能是全局或项目名，规则是名字），次要一行是文件名与存好没有；完整路径悬停看（多是一长串家目录里的点目录）。
    private func header(_ library: AgentLibrary?) -> OverlayHeader.Content {
        let entry = library?.file(file)
        return OverlayHeader.Content(
            page: .library(file), title: workspace.fileTitle(file, in: library),
            detail: library?.detail(of: file, draft: draft) ?? Dotted(),
            failed: draft?.state == .failed, help: entry.flatMap { library?.shown($0.textPath) },
            widest: Dotted(library?.fileName(file), FileDraft.longestShownState))
    }
}
#endif
