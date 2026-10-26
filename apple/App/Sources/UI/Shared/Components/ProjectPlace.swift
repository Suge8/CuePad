import CueStore
import SwiftUI

/// 项目的任务在哪个文件夹里做，给人看的那一句：项目页介绍之后（Mac 的介绍行、手机页顶那块玻璃的第二行、iPad 侧栏在旁边时页里那一行，`ProjectIntroLine`）
/// 与"⋯"里文件夹那一组的组头（`ProjectActions`）只读这一份。
/// - Mac：绑着的写本机路径（`Workspaces.shown`），点了在访达里显示；没绑的写开工时会建的工作区"~/CuePad/<名> · 开工时建好"。
/// - 手机：写在哪台 Mac 上（同步来的绑定只有文件夹名，`ProjectFolders.place`）；一台 Mac 都没有时写要一台装了 CuePad 的 Mac。
struct ProjectPlace: Equatable {
    let text: Dotted
    /// 绑着本机的文件夹（只在 Mac 上有）：点了在访达里显示。
    let folder: URL?
}

extension Workspace {
    /// 读的是内存里的项目目录（`catalog`），不另订阅；目录还没读到为 nil。
    func place(of project: Project) -> ProjectPlace? {
        guard let catalog else { return nil }
        #if os(macOS)
        if let directory = catalog.directories[project.id] {
            return ProjectPlace(text: Dotted(Workspaces.shown(directory)), folder: URL(filePath: directory, directoryHint: .isDirectory))
        }
        return ProjectPlace(text: Dotted(pendingFolder(of: project), ProjectFolders.pending), folder: nil)
        #else
        return ProjectPlace(text: ProjectFolders.place(of: project, bindings: catalog.bindings, workMac: catalog.workMac), folder: nil)
        #endif
    }

    #if os(macOS)
    /// 没绑文件夹的项目第一次开工时建的工作区，给人看的写法（`Workspaces.shown`）；接入面板说任务在哪做也读它。
    func pendingFolder(of project: Project) -> String {
        Workspaces.shown(services.workspaces.directory(for: project.name).path(percentEncoded: false))
    }
    #endif
}

/// 一枚文件夹图标接 `ProjectPlace` 那一句，一行、太长从中间省略（路径的头尾都要紧）；Mac 上绑着本机文件夹的点了在访达里显示。
struct ProjectPlaceLabel: View {
    let place: ProjectPlace

    var body: some View {
        let label = HStack(spacing: 4) {
            Image(.folder).imageScale(.small).accessibilityHidden(true)
            Text(place.text).lineLimit(1).truncationMode(.middle)
        }
        #if os(macOS)
        if let folder = place.folder {
            Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { label }
                .buttonStyle(PressStyle(.inline))
                .help("在访达中显示")
        } else {
            label
        }
        #else
        label
        #endif
    }
}

/// 项目页最上面那一行：项目的一句介绍接它的文件夹（`ProjectPlace`），Mac 项目页与 iPad 侧栏在旁边时的项目页同一行（那时页顶不写标题与第二行）。
/// 目录读到之前、没写介绍时也占着这一行的高：下面的任务纸与墙不上下跳。介绍优先占宽，文件夹在后面从中间省略。
struct ProjectIntroLine: View {
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let intro = project?.intro, place = project.flatMap(workspace.place(of:))
        HStack(spacing: 0) {
            if let intro {
                Text(intro).foregroundStyle(palette.ink2)
                    .lineLimit(1).truncationMode(.tail).help(intro).textSelection(.enabled)
                    .layoutPriority(1)
                if place != nil { Dotted.inline.foregroundStyle(palette.ink3).accessibilityHidden(true) }
            }
            if let place { ProjectPlaceLabel(place: place).foregroundStyle(palette.ink3) }
            Text(verbatim: " ").accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .font(Typography.secondary)
    }
}
