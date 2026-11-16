import CueStore
import SwiftUI

struct ProjectCard: View {
    let project: Project
    let ideaCount: Int
    let openTasks: Int
    let modifiedAt: Date
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectPixelCover(pattern: .cover(ProjectIcon(stored: project.icon)))
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                    ProjectGlyph(project: project, size: Glyph.projectIdentity)
                    Text(verbatim: project.shownName)
                        .font(Typography.bodyStrong)
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if project.isPinned {
                        Image(.pin).font(Glyph.small).foregroundStyle(palette.ink2).iconLabel("已置顶")
                    }
                }
                metadata
            }
            .padding(.horizontal, Spacing.group)
            .padding(.vertical, Spacing.item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.note(project.color))
        }
        .clipShape(.rect(cornerRadius: Radius.card))
        // 与点进去之后项目页的灵感卡同一种淡彩纸：在列表里就认得出是哪个项目
        .paper(wash: palette.note(project.color))
        .contentShape(.rect(cornerRadius: Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.item) { counts; updated }.fixedSize()
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.item) { counts }
                updated
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Spacing.hair) { counts; updated }
        }
        .font(Typography.caption)
        .foregroundStyle(palette.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var updated: some View {
        if modifiedAt.timeIntervalSince1970 > 0 {
            LiveText(style: SessionClock.ago(modifiedAt).live(.list)) { Text("\($0)更新") }
                .foregroundStyle(palette.ink3)
        } else {
            Text("尚未更新").foregroundStyle(palette.ink3)
        }
    }

    @ViewBuilder private var counts: some View {
        Text("\(ideaCount) 灵感")
        Text("\(openTasks) 未完成")
            .accessibilityLabel(Text("\(openTasks) 个任务没做完"))
    }
}
