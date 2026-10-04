#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 目标与下一步：目标卡 + 本项目未完成任务 + 本项目的 Pi 会话。没有目标卡时不显示目标一栏。
struct FocusBand: View {
    let data: ProjectPageData
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let visibleTasks = 4
    /// 窄于这个宽度时三栏改成上下排，每栏都能放下一整行任务。
    private static let stackedBelow: CGFloat = 820

    var body: some View {
        // 由排版当场选：横排的理想宽度钉在 stackedBelow，放得下就横排，否则上下排。不读几何、不写状态
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                if let card = data.goalCard {
                    column { goal(card) }
                    divider
                }
                column { tasks }
                divider
                column { PiColumn(project: data.project?.id, hasDirectory: data.project.flatMap { workspace.catalog?.directories[$0.id] } != nil) }
                    .frame(maxWidth: 300)
            }
            .frame(minWidth: Self.stackedBelow, idealWidth: Self.stackedBelow, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                if let card = data.goalCard {
                    column { goal(card) }
                    Divider().overlay(palette.hair).padding(.horizontal, 18)
                }
                column { tasks }
                Divider().overlay(palette.hair).padding(.horizontal, 18)
                column { PiColumn(project: data.project?.id, hasDirectory: data.project.flatMap { workspace.catalog?.directories[$0.id] } != nil) }
            }
        }
        .paper(radius: 18)
    }

    @ViewBuilder private func goal(_ card: Card) -> some View {
        SectionLabel(text: "目标", systemImage: "scope")
        let text = CardText(card.body)
        Button {
            workspace.openCard = card.id
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
        .buttonStyle(CardOpenStyle())
        .cardPresence(card.id, in: workspace)
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
            Text(hasDirectory ? "没有运行中的会话" : "还没绑定代码目录")
                .font(.system(size: 12.5)).foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(sessions) { session in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    PiStateDot(state: session.state.work, size: 5)
                    Text(session.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                    Spacer()
                    Text("已持续 \(Text(session.stateSince, style: .timer))").font(.system(size: 11).monospacedDigit()).foregroundStyle(palette.ink3)
                }
                Text(session.state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(session.state.labelColor(palette))
                PiDetail(state: session.state)
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
                        PiStateDot(state: session.state.work, size: 5)
                        Text("\(session.displayName) \(session.state.label)")
                    }
                    .foregroundStyle(palette.ink2)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16).frame(height: 34)
            .paper(radius: 17, lifted: true)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        // 放在工具栏里时系统默认只显示图标
        .labelStyle(.titleAndIcon)
        .help("回到顶部")
    }
}
#endif
