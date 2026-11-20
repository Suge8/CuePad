import CueStore
import SwiftUI

/// 等你列的卡同别的列一样大、一样的纸：名字带拍板还是新回复，它等你的那一句写两行，点一下进会话，在那里读全、作答。
/// 否决过：一次摊开一张、与页面反色、选项与回复框都在卡上——一块反色的大面压过整页，句子长了在窄卡里堆成一摞、读不成段，要答还是得点进去。
struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardRow) private var row

    var body: some View {
        link {
            VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                BoardWaitFace(held: held, ask: ask)
                if row { Spacer(minLength: 0) }
                BoardWaitFoot(held: held, project: project)
            }
            .padding(.vertical, BoardCardMetrics.pad).boardCard(.waiting)
        }
        .contextMenu { menu }
        .boardDim(project: held.project)
    }

    private var spoken: String { Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "新回复"), ask).spoken }

    private func link(@ViewBuilder _ label: () -> some View) -> some View {
        let label = label()
        return BoardLink(to: held.session) {
            #if os(macOS)
            // 悬停提示里等了多久跟着走：到下一次换字的时刻（`SessionClock.Waited`）只重画卡面，挂着菜单的那一层不随时间重建
            Moments(next: SessionClock.Waited(since: held.session.stateSince).discreteInput(after:)) { now in label.help(tip(at: now)) }
            #else
            label
            #endif
        }
        .accessibilityLabel(spoken)
        .accessibilityActions { menu }
        .completionAsks(claiming: held.item?.task.id)
    }

    /// 等你的是哪一句：拍板是它问的那句，待回复是它最后说的那句的头一句。
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
            workspace.catalog?.project(held.project)?.shownName, held.deciding ? held.session.asked.line : String(localized: "新回复"),
            SessionClock.Waited(since: held.session.stateSince).format(now)
        ).visible
    }
    #endif
}

/// 同推进中那张卡的骨架（`BoardCardLayout`）：名字带拍板还是待回复、Agent，等你的那一句，卡脚（`BoardWaitFoot`）是项目与等了多久。
private struct BoardWaitFace: View {
    let held: TaskBoard.Held
    let ask: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    if held.item?.task.isPinned == true { BoardPin() }
                    BoardCardTitle(held.title).foregroundStyle(palette.ink)
                    Text(held.deciding ? "拍板" : "新回复").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.waiting).fixedSize()
                        .padding(.leading, Spacing.hair)
                }
                .font(Typography.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                AgentMark(session: held.session, font: TaskMetrics.caption, named: false)
            }
            if let ask {
                Text(verbatim: ask).font(TaskMetrics.caption).foregroundStyle(palette.ink2)
                    .lineLimit(Self.lines).multilineTextAlignment(.leading)
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
        .frame(height: BoardCardMetrics.vitals)
    }
}
