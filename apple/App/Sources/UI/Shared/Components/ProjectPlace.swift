import CueStore
import SwiftUI

/// 项目页介绍之后（`ProjectIntroLine`）与"⋯"里文件夹那一组的组头（`ProjectActions`）只读这一份。
struct ProjectPlace: Equatable {
    let text: Dotted
    let folder: URL?
    let isPath: Bool

    var shortText: Dotted {
        guard isPath, let path = text.parts.first else { return text }
        let name = URL(filePath: path, directoryHint: .isDirectory).lastPathComponent
        return Dotted([name] + text.parts.dropFirst())
    }
}

extension Workspace {
    /// 读的是内存里的项目目录（`catalog`），不另订阅；目录还没读到为 nil。
    func place(of project: Project) -> ProjectPlace? {
        guard let catalog else { return nil }
        #if os(macOS)
        if let directory = catalog.directories[project.id] {
            return ProjectPlace(text: Dotted(UserHome.shown(directory)), folder: URL(filePath: directory, directoryHint: .isDirectory), isPath: true)
        }
        return ProjectPlace(text: Dotted(pendingFolder(of: project), ProjectFolders.pending), folder: nil, isPath: true)
        #else
        return ProjectPlace(text: ProjectFolders.place(of: project, bindings: catalog.bindings, workMac: catalog.workMac), folder: nil, isPath: false)
        #endif
    }

    #if os(macOS)
    /// 接入面板说任务在哪做也读它。
    func pendingFolder(of project: Project) -> String {
        UserHome.shown(services.workspaces.directory(for: project.name).path(percentEncoded: false))
    }
    #endif
}

/// 一行：几段的放得下几段写几段，去掉的接一个"…"，不拦腰截断一段（连头一段都放不下才从尾部省略），读屏照读全部。
struct ProjectPlaceLabel: View {
    let place: ProjectPlace
    var icon = true

    var body: some View {
        let label = HStack(spacing: Spacing.tight) {
            if icon { Image(.folder).imageScale(.small).readerHidden(true) }
            if place.isPath {
                Text(place.shortText).lineLimit(1).truncationMode(.middle).accessibilityLabel(place.text.spoken)
            } else {
                segments
            }
        }
        #if os(macOS)
        if let folder = place.folder {
            Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { label }
                .buttonStyle(PressStyle(.inline))
                .help(place.text.visible)
        } else {
            label.help(place.text.visible)
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

/// 宽屏（Mac、iPad）项目页最上面那一行不写介绍（`intro: false`）：项目名与介绍已在主栏栏头（`WideProjectHeading`），这里只剩文件夹与"规则"。
/// 目录读到之前、没写介绍时也占着这一行的高：下面的任务纸与墙、玻璃里的标题不上下跳。介绍优先占宽，文件夹在后面省略。
struct ProjectIntroLine: View {
    let project: Project?
    var inHeader = false
    var intro = true
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let intro = self.intro ? project?.intro : nil, place = project.flatMap(workspace.place(of:))
        HStack(spacing: 0) {
            if let intro {
                Text(intro).foregroundStyle(inHeader ? palette.ink3 : palette.ink2)
                    .lineLimit(1).truncationMode(.tail).help(intro).textSelection(.enabled)
                    .layoutPriority(1)
                if place != nil { Dotted.inline.foregroundStyle(palette.ink3).readerHidden(true) }
            }
            if let place { ProjectPlaceLabel(place: place, icon: !inHeader).foregroundStyle(palette.ink3) }
            if !inHeader, let project, let rules = workspace.rules(of: project.id) {
                Dotted.inline.foregroundStyle(palette.ink3).readerHidden(true)
                Button { workspace.openLibrary(rules) } label: {
                    Label("规则", icon: .instruction).labelStyle(.titleAndIcon).imageScale(.small)
                }
                .buttonStyle(PressStyle(.inline))
                .foregroundStyle(palette.ink2)
                .fixedSize()
                .help("这个项目的 AGENTS.md")
            }
            Text(verbatim: " ").readerHidden(true)
        }
        .font(inHeader ? .caption : Typography.secondary)
        // 靠左铺满用外框，不在行里放 Spacer：Spacer 与文件夹那段分剩下的宽，几段的放得下也只给一段
        .frame(maxWidth: inHeader ? nil : .infinity, alignment: .leading)
    }
}
