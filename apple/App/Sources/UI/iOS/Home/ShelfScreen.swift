#if os(iOS)
import CueStore
import SwiftUI

/// 项目页（窄屏标签栏的"项目"）：顶上中间一条搜索框（`Dock.search`），右上"新建项目"。
/// 宽屏侧栏已列出全部项目、顶上有搜索框，没有进这一页的入口：只在正看着的项目进了回收站时退回这里（`Workspace.pop`），顶上只有"新建项目"。
/// 只排项目（在发生什么在进展页）：置顶项目是纸卡（`pinnedGrid`：图标、名字、介绍），其余排成一张纸上的行，长相同侧栏的项目行（只有图标与名字）。
/// 窄屏（iPhone）没有侧栏，末尾一组归档、回收站、设置（同步到不了 Mac 时设置那一行带点，`AppServices.macAlert`）推在这一页上；宽屏这一组在侧栏里，这里不放。
struct ShelfScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var narrow: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            if let catalog = workspace.catalog { content(catalog) }
        }
        .refreshable { await services.syncNow() }
        .floatingHeader(.verbatim(SidebarOutline.Entry.projects.title)) {
            Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
        }
    }

    private func content(_ catalog: ProjectCatalog) -> some View {
        let pinned = catalog.projects.filter(\.isPinned)
        let rest = catalog.projects.filter { !$0.isPinned }
        let wide = !narrow && !typeSize.isAccessibilitySize
        return LazyVStack(alignment: .leading, spacing: Self.sectionGap) {
            if !pinned.isEmpty {
                // 置顶卡平分整行：iPhone 至多两列，宽屏至多四列，不留一排窄卡靠左
                pinnedGrid(pinned, columns: typeSize.isAccessibilitySize ? 1 : min(pinned.count, wide ? 4 : 2))
            }
            if !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rest) { ShelfRow(project: $0) }
                }
                .padding(.vertical, Self.paperInset)
                .rowPaper(radius: Self.radius)
            }
            if narrow { ShelfFooter() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .animation(Motion.nudge, value: catalog.projects.map(\.id))
        // 宽屏不把一行项目拉满整屏
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private static let readableWidth: CGFloat = 1080
    private static let sectionGap: CGFloat = 20
    static let radius: CGFloat = 20
    /// 纸的上下沿比行间多留的白。
    static let paperInset: CGFloat = 6

    /// 置顶卡按行排：每行 `columns` 张平分整行，最后一行不满时那几张也平分整行，不留空格；最后一行只剩一张时它占满整行、
    /// 横着排成矮的一条（`wide`）——不让单出来的那张（常是最不活跃、甚至空的项目）成为首屏最大的一块。
    /// 一行里的卡同高。置顶的不多，不用懒加载。
    private func pinnedGrid(_ pinned: [Project], columns: Int) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: pinned.count, by: columns)), id: \.self) { start in
                let row = pinned[start..<min(start + columns, pinned.count)]
                HStack(spacing: 12) {
                    ForEach(row) { PinnedShelfCard(project: $0, wide: row.count == 1 && columns > 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 置顶项目的纸卡：项目色从上沿淡下来的一层底、图标、名字、介绍。`wide`：一行里单出来的那张占满整行，横着排成矮的一条，图标在左。
private struct PinnedShelfCard: View {
    let project: Project
    var wide = false
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 22

    private static let radius: CGFloat = 20

    var body: some View {
        let wash = palette.projectWash(project.color)
        NavigationLink(value: Route.project(project.id)) {
            Group {
                if wide {
                    HStack(spacing: 12) {
                        ProjectGlyph(project: project, size: glyph)
                        VStack(alignment: .leading, spacing: 4) { lines }
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ProjectGlyph(project: project, size: glyph).padding(.bottom, 8)
                        lines
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 渐变只铺在填充上（不用渐变描边，见 docs/ui.md「渲染性能约束」）
            .background(
                LinearGradient(colors: [wash, wash.opacity(0)], startPoint: wide ? .leading : .top, endPoint: .center),
                in: .rect(cornerRadius: Self.radius, style: .continuous))
            .paper(radius: Self.radius)
        }
        .buttonStyle(PressStyle(.card))
        .projectActions(project, radius: Self.radius)
        .accessibilityElement(children: .combine)
    }

    /// 没写介绍也占着介绍那一行：置顶卡一样高，单出来的一张、一整行都没介绍的不比别的行矮。
    @ViewBuilder private var lines: some View {
        let intro = project.intro?.nonEmpty
        Text(project.shownName).font(.title3.weight(.bold)).foregroundStyle(palette.ink).lineLimit(1)
        Text(intro ?? " ").font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1).accessibilityHidden(intro == nil)
    }
}

/// 项目的一行，长相同侧栏的项目行：图标与名字（条数、状态与"此刻"都不写：在发生什么在进展页）。辅助字号下名字可换行。
private struct ShelfRow: View {
    let project: Project
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    var body: some View {
        NavigationLink(value: Route.project(project.id)) {
            Label {
                Text(project.shownName).font(.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            } icon: {
                ProjectGlyph(project: project, size: glyph)
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .projectActions(project, radius: ShelfScreen.radius)
        .accessibilityElement(children: .combine)
    }
}

/// 窄屏末尾那一组：归档、回收站、设置（`SidebarOutline.footer`，同侧栏底部），点了推在项目页上。
private struct ShelfFooter: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SidebarOutline.footer, id: \.self) { entry in
                ShelfLine(route: entry.route, icon: entry.icon, title: entry.title, alert: entry == .settings ? services.macAlert : nil)
            }
        }
        .padding(.vertical, ShelfScreen.paperInset)
        .rowPaper(radius: ShelfScreen.radius)
    }
}

/// 末尾那一组的一行：图标、名字，行尾是同步到不了 Mac 的点（只有设置）、条数与箭头，点进一页。
/// 图标与名字同项目行一样排（`Label`，图标槽同 `ProjectGlyph` 宽）：两组的图标列与字的起点在同一条竖线上。
private struct ShelfLine: View {
    let route: Route
    let icon: Icon
    let title: String
    var alert: SyncSummary?
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Label {
                    Text(title).foregroundStyle(palette.ink)
                } icon: {
                    IconImage(icon).font(.system(size: glyph)).foregroundStyle(palette.ink).frame(width: glyph + 6).accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                if let alert { Circle().fill(palette.color(alert.tone)).frame(width: 7, height: 7).accessibilityHidden(true) }
                Image(.forward).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .accessibilityElement(children: .combine)
        .accessibilityValue(alert?.title ?? "")
    }
}
#endif
