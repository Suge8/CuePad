#if os(macOS)
import CueStore
import SwiftUI

/// 侧栏收起时工具栏里的当前页胶囊：点开是项目切换列表，前 9 个带 ⌘1–9 提示（与窗口快捷键同一顺序），之后是侧栏里别的去处（Cue 在最前，同侧栏）。
struct ProjectSwitcher: View {
    /// 侧栏收起时才写当前页：展开时标签是空的，切页不碰这个常驻的菜单（标签一变整份菜单跟着重建，一次切页约 7ms）。
    let collapsed: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let numbered = 9

    var body: some View {
        let projects = workspace.catalog?.projects ?? []
        Menu {
            Button { workspace.show(.cue) } label: { Label(workspace.cue.name, icon: .cue).labelStyle(.titleAndIcon) }
            Divider()
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
            let progress = SidebarOutline.Entry.progress
            Button { workspace.show(progress.route) } label: { Label(progress.title, icon: progress.icon).labelStyle(.titleAndIcon) }
            Button { workspace.show(.archive) } label: { Label("归档", icon: .archive).labelStyle(.titleAndIcon) }
            Button { workspace.show(.trash) } label: { Label("回收站", icon: .trash).labelStyle(.titleAndIcon) }
        } label: {
            HStack(spacing: 6) {
                if collapsed {
                    CurrentPage(projects: projects)
                    Image(.expand).font(.system(size: 9, weight: .bold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                }
            }
            .font(Typography.toolbarLabel.weight(.semibold))
            .menuLabel("当前项目，点按切换")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换项目（⌘1–9）")
    }

    /// 菜单项里 SwiftUI 的前景色不生效，用带项目色的非模板符号图。
    /// 按（符号，颜色）缓存：菜单每次重算（侧栏收起、每次开合）都要给每个项目配一张，现建一张约半毫秒。
    private static var menuIcons: [String: NSImage] = [:]

    private static func menuIcon(_ project: Project) -> NSImage {
        let key = "\(project.icon ?? "")|\(project.color)"
        if let cached = menuIcons[key] { return cached }
        let image = makeMenuIcon(project)
        menuIcons[key] = image
        return image
    }

    private static func makeMenuIcon(_ project: Project) -> NSImage {
        // 菜单图标缓存成 NSImage、拿不到外观：用动态色，系统画菜单时按当时的外观取浅深两档
        let color = NSColor(name: nil) { appearance in
            NSColor(Palette(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua).project(project.color))
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = ProjectGlyph.icon(project).platformImage?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// 胶囊里的当前页：单独一个视图读 `workspace.root`，切页时只重算它，不重算上面那份包含全部项目的菜单。Mac 的每一页都有一个写法（`MainWindow.pageView`），胶囊不空着只剩箭头。
private struct CurrentPage: View {
    let projects: [Project]
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch workspace.root {
        case .cue:
            Image(.cue).accessibilityHidden(true)
            Text(workspace.cue.name)
        case .project(let id):
            let project = projects.first { $0.id == id }
            ProjectGlyph(project: project, size: 12)
            Text(project?.name ?? "")
        case .archive:
            Image(.archive).accessibilityHidden(true)
            Text("归档")
        case .trash:
            Image(.trash).accessibilityHidden(true)
            Text("回收站")
        case .progress, .session:
            let progress = SidebarOutline.Entry.progress
            Image(progress.icon).accessibilityHidden(true)
            Text(progress.title)
        default:
            EmptyView()
        }
    }
}
#endif
