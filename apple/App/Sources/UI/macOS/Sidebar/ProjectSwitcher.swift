#if os(macOS)
import CueStore
import SwiftUI

/// 侧栏收起时工具栏里的当前项目胶囊：点开是项目切换列表，前 9 个带 ⌘1–9 提示（与窗口快捷键同一顺序）。
struct ProjectSwitcher: View {
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
                Button { workspace.show(.inbox) } label: { Label("未分类", systemImage: "tray").labelStyle(.titleAndIcon) }
            }
            Button { workspace.show(.trash) } label: { Label("回收站", systemImage: "trash").labelStyle(.titleAndIcon) }
        } label: {
            HStack(spacing: 6) {
                current(projects)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换项目（⌘1–9）")
        .accessibilityLabel("当前项目，点按切换")
    }

    /// 菜单项里 SwiftUI 的前景色不生效，用带项目色的非模板符号图。
    private static func menuIcon(_ project: Project) -> NSImage {
        let color = NSColor(Palette.projectTint(project.color))
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: ProjectGlyph.symbol(project.icon), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }

    @ViewBuilder private func current(_ projects: [Project]) -> some View {
        switch workspace.page {
        case .project(let id):
            let project = projects.first { $0.id == id }
            ProjectGlyph(project: project, size: 12)
            Text(project?.name ?? "")
        case .inbox:
            Image(systemName: "tray").accessibilityHidden(true)
            Text("未分类")
        case .archive:
            Image(systemName: "archivebox").accessibilityHidden(true)
            Text("归档")
        case .trash:
            Image(systemName: "trash").accessibilityHidden(true)
            Text("回收站")
        }
    }
}
#endif
