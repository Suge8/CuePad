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
    /// 头一段是本机路径（Mac）：放不下从中间省略，头尾都要紧；手机上是几段"X 上的 Y"，放不下整段整段地从尾部去掉（`ProjectPlaceLabel`）。
    let isPath: Bool
}

extension Workspace {
    /// 读的是内存里的项目目录（`catalog`），不另订阅；目录还没读到为 nil。
    func place(of project: Project) -> ProjectPlace? {
        guard let catalog else { return nil }
        #if os(macOS)
        if let directory = catalog.directories[project.id] {
            return ProjectPlace(text: Dotted(Workspaces.shown(directory)), folder: URL(filePath: directory, directoryHint: .isDirectory), isPath: true)
        }
        return ProjectPlace(text: Dotted(pendingFolder(of: project), ProjectFolders.pending), folder: nil, isPath: true)
        #else
        return ProjectPlace(text: ProjectFolders.place(of: project, bindings: catalog.bindings, workMac: catalog.workMac), folder: nil, isPath: false)
        #endif
    }

    #if os(macOS)
    /// 没绑文件夹的项目第一次开工时建的工作区，给人看的写法（`Workspaces.shown`）；接入面板说任务在哪做也读它。
    func pendingFolder(of project: Project) -> String {
        Workspaces.shown(services.workspaces.directory(for: project.name).path(percentEncoded: false))
    }
    #endif
}

/// `ProjectPlace` 那一句（`icon` 时前面一枚文件夹图标），一行：本机路径太长从中间省略；几段的放得下几段写几段，去掉的接一个"…"，
/// 不拦腰截断一段（连头一段都放不下才从尾部省略），读屏照读全部。Mac 上绑着本机文件夹的点了在访达里显示。
struct ProjectPlaceLabel: View {
    let place: ProjectPlace
    var icon = true

    var body: some View {
        let label = HStack(spacing: 4) {
            if icon { Image(.folder).imageScale(.small).accessibilityHidden(true) }
            if place.isPath {
                Text(place.text).lineLimit(1).truncationMode(.middle)
            } else {
                segments
            }
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

    private var segments: some View {
        let parts = place.text.parts
        return ViewThatFits(in: .horizontal) {
            ForEach((1...max(parts.count, 1)).reversed(), id: \.self) { count in
                Text(Dotted(parts.prefix(count) + (count < parts.count ? ["…"] : []))).lineLimit(1).fixedSize()
            }
            Text(Dotted(parts.first)).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.text.spoken)
    }
}

/// 项目的一句介绍接它的文件夹（`ProjectPlace`）：Mac 项目页与 iPad 侧栏在旁边时项目页最上面那一行（那时页顶不写标题与第二行），
/// `inHeader` 时是手机页顶那块玻璃的第二行（小一号、同一档墨、不带图标，同 `floatingHeader` 的信息行）。
/// 目录读到之前、没写介绍时也占着这一行的高：下面的任务纸与墙、玻璃里的标题不上下跳。介绍优先占宽，文件夹在后面省略（规则见 `ProjectPlaceLabel`）。
/// 绑着文件夹的项目（技能与规则的快照里有它）行末一个"规则"，点了直接打开这个项目的 AGENTS.md 编辑页；手机页顶那块玻璃里不放，在右上"⋯"里。
struct ProjectIntroLine: View {
    let project: Project?
    var inHeader = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let intro = project?.intro, place = project.flatMap(workspace.place(of:))
        HStack(spacing: 0) {
            if let intro {
                Text(intro).foregroundStyle(inHeader ? palette.ink3 : palette.ink2)
                    .lineLimit(1).truncationMode(.tail).help(intro).textSelection(.enabled)
                    .layoutPriority(1)
                if place != nil { Dotted.inline.foregroundStyle(palette.ink3).accessibilityHidden(true) }
            }
            if let place { ProjectPlaceLabel(place: place, icon: !inHeader).foregroundStyle(palette.ink3) }
            if !inHeader, let project, let rules = workspace.rules(of: project.id) {
                Dotted.inline.foregroundStyle(palette.ink3).accessibilityHidden(true)
                Button { workspace.openLibrary(rules) } label: {
                    Label("规则", icon: .instruction).labelStyle(.titleAndIcon).imageScale(.small)
                }
                .buttonStyle(PressStyle(.inline))
                .foregroundStyle(palette.ink2)
                .fixedSize()
                .help("这个项目的 AGENTS.md")
            }
            Text(verbatim: " ").accessibilityHidden(true)
        }
        .font(inHeader ? .caption : Typography.secondary)
        // 靠左铺满用外框，不在行里放 Spacer：Spacer 与文件夹那段分剩下的宽，几段的放得下也只给一段
        .frame(maxWidth: inHeader ? nil : .infinity, alignment: .leading)
    }
}
