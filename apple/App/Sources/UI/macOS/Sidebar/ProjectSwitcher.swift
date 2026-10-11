#if os(macOS)
import CueStore
import SwiftUI

/// 侧栏收起时工具栏里的当前项目胶囊：点开是项目切换列表，前 9 个带 ⌘1–9 提示（与窗口快捷键同一顺序）。
struct ProjectSwitcher: View {
    /// 侧栏收起时才写当前页：展开时标签是空的，切页不碰这个常驻的菜单（标签一变整份菜单跟着重建，一次切页约 7ms）。
    let collapsed: Bool
    @Environment(Workspace.self) private var workspace

    private static let numbered = 9

    var body: some View {
        let projects = workspace.catalog?.projects ?? []
        Menu {
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                let item = Button { workspace.show(.project(project.id)) } label: {
                    Label { Text(project.name) } icon: { Image(nsImage: Self.menuIcon(project)) }
                        .labelStyle(.titleAndIcon)
                }
                if index < Self.numbered {
                    item.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                } else {
                    item
                }
            }
            Divider()
            if (workspace.catalog?.cardCounts[nil] ?? 0) > 0 {
                Button { workspace.show(.unfiled) } label: { Label(CaptureCopy.unfiled, systemImage: "tray").labelStyle(.titleAndIcon) }
            }
            Button { workspace.show(.agent) } label: { Label("Agent", systemImage: "sparkles").labelStyle(.titleAndIcon) }
            Button { workspace.show(.archive) } label: { Label("归档", systemImage: "archivebox").labelStyle(.titleAndIcon) }
            Button { workspace.show(.trash) } label: { Label("回收站", systemImage: "trash").labelStyle(.titleAndIcon) }
        } label: {
            HStack(spacing: 6) {
                if collapsed {
                    CurrentPage(projects: projects)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .font(Typography.toolbarLabel.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换项目（⌘1–9）")
        .accessibilityLabel("当前项目，点按切换")
    }

    /// 菜单项里 SwiftUI 的前景色不生效，用带项目色的非模板符号图。
    /// 按（符号，颜色）缓存：菜单每次重算（侧栏收起、每次开合）都要给每个项目配一张，现建一张约半毫秒。
    private static var menuIcons: [String: NSImage] = [:]

    private static func menuIcon(_ project: Project) -> NSImage {
        let key = "\(ProjectGlyph.symbol(project.icon))|\(project.color)"
        if let cached = menuIcons[key] { return cached }
        let image = makeMenuIcon(project)
        menuIcons[key] = image
        return image
    }

    private static func makeMenuIcon(_ project: Project) -> NSImage {
        let color = NSColor(Palette.projectTint(project.color))
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: ProjectGlyph.symbol(project.icon), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// 胶囊里的当前页：单独一个视图读 `workspace.page`，切页时只重算它，不重算上面那份包含全部项目的菜单。
private struct CurrentPage: View {
    let projects: [Project]
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch workspace.page {
        case .project(let id):
            let project = projects.first { $0.id == id }
            ProjectGlyph(project: project, size: 12)
            Text(project?.name ?? "")
        case .unfiled:
            Image(systemName: "tray").accessibilityHidden(true)
            Text(CaptureCopy.unfiled)
        case .archive:
            Image(systemName: "archivebox").accessibilityHidden(true)
            Text("归档")
        case .trash:
            Image(systemName: "trash").accessibilityHidden(true)
            Text("回收站")
        case .agent, .session:
            Image(systemName: "sparkles").accessibilityHidden(true)
            Text("Agent")
        default:
            EmptyView()
        }
    }
}
#endif
