import CueStore
import SwiftUI

/// 封面由图标固定映射，改名、计数或时间变化都不换图。
struct ProjectCard: View {
    let project: Project
    let ideaCount: Int
    let openTasks: Int
    let modifiedAt: Date
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectPixelCover(style: ProjectIcon(stored: project.icon).cover)
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
            .background(palette.paper)
        }
        .clipShape(.rect(cornerRadius: Radius.card))
        .paper(wash: palette.paper)
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
            LiveText(style: PiClock.ago(modifiedAt).live(.list)) { Text("\($0)更新") }
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

extension ProjectIcon {
    var cover: ProjectCoverStyle {
        switch self {
        case .chat, .music: .whale
        case .rocket, .hammer: .shark
        case .layers, .cube: .jellyfish
        case .globe, .flag: .turtle
        case .target, .bolt: .fox
        case .house, .heart: .cat
        case .camera, .megaphone: .penguin
        case .book, .lightbulb: .owl
        case .leaf, .paintbrush: .monstera
        case .cart, .terminal: .cactus
        case .folder, .briefcase: .mushroom
        case .sparkles, .star: .flower
        }
    }
}
