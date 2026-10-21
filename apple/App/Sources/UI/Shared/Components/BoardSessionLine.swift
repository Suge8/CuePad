import CueStore
import SwiftUI

/// 推进中里一个没绑没做完的任务的活会话（终端里开的、"新会话"、只有已完成的事绑着的）：与任务行（`TaskLine`）同一个语法——
/// 领头格是会话图形（终端，不用会话页那条心电线：它与行尾在跑的状态标同形；任务是完成圈），标题是会话名（同任务标题的字，不用等宽字、不放 Agent 品牌标），行尾按档写（`BoardPulse`：
/// 要你管的写状态词，在跑的是会动的状态标加时长，歇着的只写时长、标题淡一档），看全部项目时末尾是它归处的项目小图标。点了打开会话。
struct BoardSessionLine: View {
    let session: PiSessionState
    /// 行尾的项目小图标（看全部项目时，`BoardLook.project`）。
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = workspace.shown(session, delivery: services.liveSessions.deliveries[session.sessionID])
        let pulse = BoardPulse(shown: shown, session: session)
        let next = TaskNext(shown: shown, session: session, startable: nil)
        let resting = pulse.tier == .resting
        BoardLink(to: .session(session)) {
            HStack(alignment: .firstTextBaseline, spacing: TaskMetrics.columnGap) {
                Image(.terminal).font(.system(size: Self.lead)).foregroundStyle(resting ? palette.ink3 : palette.ink2)
                    .frame(width: TaskMetrics.ringColumn)
                TaskLineLayout(trailing: true) {
                    Text(session.title).font(TaskMetrics.lineFont).foregroundStyle(resting ? palette.ink2 : palette.ink)
                        .lineLimit(Self.titleLines).padding(.vertical, Self.titlePadding)
                    if let next, pulse.showsMark { TaskNextMark(next: next).yields(first: false, ever: !next.speaks) }
                    if !shown.speaksOnTask, let meter = pulse.fullContext { ContextFact(meter: meter).font(TaskMetrics.caption).fixedSize() }
                    if !pulse.speaks {
                        LiveText(style: PiClock.Elapsed(since: shown.clock?.since ?? session.stateSince))
                            .font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink3)
                            .yields(first: true)
                    }
                    if let project { BoardRowEnd(project: project) }
                }
            }
            .frame(minHeight: TaskMetrics.rowHeight)
        }
        .padding(.vertical, Self.rowPadding)
        .accessibilityLabel(Dotted(session.title, pulse.fullContext.map { $0.help.spoken } ?? shown.label).spoken)
    }

    #if os(macOS)
    private static let lead: CGFloat = 14
    private static let titleLines = 1
    private static let titlePadding: CGFloat = 0
    /// 同任务行（`TaskLine` 的 `framed`）上下各留的一点。
    private static let rowPadding: CGFloat = 1
    #else
    private static let lead: CGFloat = 19
    private static let titleLines = 2
    private static let titlePadding: CGFloat = 10
    private static let rowPadding: CGFloat = 0
    #endif
}
