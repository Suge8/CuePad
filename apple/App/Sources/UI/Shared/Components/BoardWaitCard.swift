import CueStore
import SwiftUI

struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardRow) private var row

    var body: some View {
        link {
            VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                BoardWaitFace(held: held, ask: ask).frame(maxHeight: row ? .infinity : nil, alignment: .top)
                BoardWaitFoot(held: held, project: project)
            }
            .padding(.vertical, BoardCardMetrics.pad).boardCard(.waiting)
        }
        .contextMenu { menu }
        .boardDim(project: held.project)
    }

    private var spoken: String { Dotted(held.title, held.shown.label, ask).spoken }

    private func link(@ViewBuilder _ label: () -> some View) -> some View {
        let label = label()
        return BoardLink(to: held.session) {
            #if os(macOS)
            Moments(next: SessionClock.Waited(since: held.session.stateSince).discreteInput(after:)) { now in label.help(tip(at: now)) }
            #else
            label
            #endif
        }
        .accessibilityLabel(spoken)
        .accessibilityActions { menu }
        .completionAsks(claiming: held.item?.task.id)
    }

    private var ask: String? {
        held.deciding ? SessionProgress.firstLine(held.session.question?.displayText ?? held.session.detail) : SessionProgress.firstSentence(held.session.lastReply)
    }

    @ViewBuilder private var menu: some View {
        if let item = held.item {
            CardActions(card: item.task, opens: true, session: held.session)
        } else {
            SessionActions(session: held.session)
        }
    }

    #if os(macOS)
    private func tip(at now: Date) -> String {
        Dotted(
            workspace.catalog?.project(held.project)?.shownName, held.deciding ? held.session.asked.line : held.shown.label,
            SessionClock.Waited(since: held.session.stateSince).format(now)
        ).visible
    }
    #endif
}

private struct BoardWaitFace: View {
    let held: TaskBoard.Held
    let ask: String?
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    if held.item?.task.isPinned == true { BoardPin() }
                    BoardCardTitle(held.title).foregroundStyle(palette.ink)
                    Text(held.shown.label).font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.waiting).fixedSize()
                        .padding(.leading, Spacing.hair)
                }
                .font(Typography.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                AgentMark(session: held.session, font: TaskMetrics.caption, named: false)
            }
            if let ask {
                Text(verbatim: ask).font(TaskMetrics.caption).foregroundStyle(palette.ink2)
                    .lineLimit(row ? 1 : Self.lines).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private static let lines = 2
}

private struct BoardWaitFoot: View {
    let held: TaskBoard.Held
    let project: Project?

    var body: some View {
        BoardFoot(glyph: BoardCardMetrics.footGlyph) {
            if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
            HStack { Spacer(minLength: 0); TimeSpent(clock: .waiting(since: held.session.stateSince)).lineLimit(1).fixedSize() }
        }
        .font(TaskMetrics.caption)
        .boardFootHeight(BoardCardMetrics.vitals)
    }
}
