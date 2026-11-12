import CueStore
import SwiftUI

/// 等你列是全页唯一要你动手的地方，一次只摊开一张（`focal`）：它与页面反色（浅色里是深的、深色里是浅的），骨架与别的卡一样，问的那句写全，成果图与选项都在卡上，当场答。
/// 别的收成一张小卡，点一下换它摊开；摊开的那张点问句进会话。否决过：每张都摊开（三四件等你时一列全是选项，分不出先看哪件）。
struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    var focal = false
    var focus: () -> Void = {}
    var openShot: (PreviewOpening) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.boardRow) private var row
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if row {
                link { rowFace.boardCard(.waiting) }
            } else if focal {
                // 选项不放进打开会话的那颗钮里：钮里不套钮
                VStack(alignment: .leading, spacing: Spacing.group) {
                    link { BoardWaitFace(held: held, ask: ask, focal: true) }
                    if let shot = held.item?.shot { BoardShot(shot: shot, group: held.id, hero: true, open: openShot) }
                    WaitAnswer(wait: .session(held.session, task: held.item?.id), leading: true)
                    BoardWaitFoot(held: held, project: project)
                }
                .padding(.horizontal, TaskMetrics.cardPadding).padding(.vertical, BoardCardMetrics.pad)
                .modifier(FocalGround())
                .environment(\.colorScheme, scheme == .dark ? .light : .dark)
            } else {
                Button(action: focus) {
                    VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                        BoardWaitFace(held: held, ask: ask)
                        BoardWaitFoot(held: held, project: project)
                    }
                    .padding(.vertical, BoardCardMetrics.pad).boardCard(.waiting)
                }
                .buttonStyle(PressStyle(.card))
                .accessibilityLabel(spoken)
                .accessibilityHint("展开作答")
            }
        }
        .contextMenu { menu }
        .boardDim(project: held.project)
    }

    private var spoken: String { Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "待回复"), ask).spoken }

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
    }

    private var rowFace: some View {
        BoardCardLayout(advancing: false, project: project) {
            StateGlyph(status: held.deciding ? .asking : .awaitsReply).font(.system(size: TaskMetrics.ring))
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
        } title: {
            if held.item?.task.isPinned == true { BoardPin() }
            BoardCardTitle(held.title).foregroundStyle(palette.ink)
        }
    }

    /// 等你的是哪一句：拍板是它问的那句，待回复是它最后说的那句的头一句。
    private var ask: String? {
        held.deciding ? SessionProgress.firstLine(held.session.question?.displayText ?? held.session.detail) : SessionProgress.firstSentence(held.session.lastReply)
    }

    @ViewBuilder private var menu: some View {
        OpenSessionBeside(session: held.session)
        if let item = held.item {
            CardActions(card: item.task, leaf: item.steps == nil, opens: true, session: held.session)
        } else {
            SessionActions(session: held.session, board: SessionListItem(state: held.session))
        }
    }

    #if os(macOS)
    private func tip(at now: Date) -> String {
        Dotted(
            workspace.catalog?.project(held.project)?.shownName, held.deciding ? held.session.asked.line : String(localized: "待回复"),
            SessionClock.Waited(since: held.session.stateSince).format(now)
        ).visible
    }
    #endif
}

/// 摊开的与收着的同一副骨架，也是推进中那张卡的骨架（`BoardCardLayout`）：名字带拍板还是待回复、Agent，等你的那一句，卡脚（`BoardWaitFoot`）是项目与等了多久。
/// 摊开的那张只是反色、那一句用正文字号写全（不比名字大：名字是这张卡的标题），句子与卡脚之间放成果图与作答。
private struct BoardWaitFace: View {
    let held: TaskBoard.Held
    let ask: String?
    var focal = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    if held.item?.task.isPinned == true { BoardPin() }
                    BoardCardTitle(held.title).foregroundStyle(palette.ink)
                    Text(held.deciding ? "拍板" : "待回复").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.waiting).fixedSize()
                        .padding(.leading, Spacing.hair)
                }
                .font(Typography.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                AgentMark(session: held.session, font: TaskMetrics.caption, named: false)
            }
            if let ask {
                Text(verbatim: ask).font(focal ? Typography.body : TaskMetrics.caption).foregroundStyle(focal ? palette.ink : palette.ink2)
                    .lineLimit(focal ? Self.focalLines : Self.foldedLines).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private static let focalLines = 6
    private static let foldedLines = 2
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

/// 反色的那一面：读的是已经翻过来的配色（调用方在它外面换了 `colorScheme`），所以这里的桌面色就是对面那套的。
/// 全页只这一张带投影（别的纸平放不加，见 `boardCard`），用矮的那档：`panel` 那档晕得开，往上漫到列头垫的那条桌面色后面，露出一块方印。
private struct FocalGround: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).fill(palette.desk).elevation(.lifted)
        }
        .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius))
    }
}
