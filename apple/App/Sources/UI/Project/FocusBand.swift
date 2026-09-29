#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 目标与下一步：目标卡 + 本项目未完成任务 + 本项目的 Pi 会话。没有目标卡时不显示目标一栏。
struct FocusBand: View {
    let data: ProjectPageData
    let paperSpace: Namespace.ID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let visibleTasks = 4

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let card = data.goalCard {
                column { goal(card) }
                divider
            }
            column { tasks }
            divider
            column { PiColumn(project: data.project?.id, hasDirectory: data.directory != nil) }
                .frame(maxWidth: 300)
        }
        .paper(radius: 18)
    }

    @ViewBuilder private func goal(_ card: Card) -> some View {
        SectionLabel(text: "目标", systemImage: "scope")
        let text = CardText(card.body)
        Button {
            withAnimation(Motion.paper) { workspace.openCard = card.id }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(text.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
                if !text.preview.isEmpty {
                    Text(VariableText.styled(text.preview, palette)).font(.system(size: 13)).lineSpacing(3)
                        .foregroundStyle(palette.ink2).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var tasks: some View {
        SectionLabel(text: "下一步 · \(data.tasks.count)", systemImage: "checklist")
        ForEach(data.tasks.prefix(Self.visibleTasks)) { task in TaskRow(task: task, compact: true) }
        if data.tasks.count > Self.visibleTasks {
            Button("还有 \(data.tasks.count - Self.visibleTasks) 条") { workspace.overlay = .tasks }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.ink3)
        }
        NewTaskField(project: data.project?.id)
    }

    private var divider: some View {
        Rectangle().fill(palette.hair).frame(width: 1).padding(.vertical, 14)
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 本项目正在跑的 Pi 会话。
private struct PiColumn: View {
    let project: UUID?
    let hasDirectory: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        SectionLabel(text: "Pi", systemImage: "terminal")
        let sessions = workspace.liveSessions(in: project)
        if sessions.isEmpty {
            Text(hasDirectory ? "没有运行中的会话" : "绑定代码目录后，在其中运行的 Pi 会显示在这里")
                .font(.system(size: 12.5)).foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(sessions) { session in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    PiDot(state: session.state, size: 6)
                    Text(Workspace.sessionName(session)).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                    Spacer()
                    Text(session.stateSince, style: .timer).font(.system(size: 11).monospacedDigit()).foregroundStyle(palette.ink3)
                }
                Text(session.state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(session.state.tint)
            }
        }
    }
}

/// 下滚后收成的一行：目标（有才显示）· 下一步数 · Pi 状态；点一下回到顶部。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let goal = data.goalCard.map { CardText($0.body).title }
        let session = workspace.liveSessions(in: data.project?.id).first
        Button(action: scrollToTop) {
            HStack(spacing: 14) {
                if let goal { Label(goal, systemImage: "scope").lineLimit(1) }
                Label("下一步 \(data.tasks.count)", systemImage: "checklist").foregroundStyle(palette.ink2)
                if let session {
                    HStack(spacing: 6) {
                        PiDot(state: session.state, size: 6)
                        Text("\(Workspace.sessionName(session)) \(session.state.label)")
                    }
                    .foregroundStyle(palette.ink2)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16).frame(height: 34)
            .paper(radius: 17, lifted: true)
        }
        .buttonStyle(.plain)
        .help("回到顶部")
    }
}
#endif
