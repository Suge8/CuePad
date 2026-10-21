import CueStore
import SwiftUI

/// 会话页读到的会话（Mac 与手机同一份）：一条列表，"现在"置顶——全部在线的与正在唤醒的（`PiSessionListItem.isCurrent`；不多，不分页），
/// 按要你注意的先后；"历史"接在下面——已结束的（"现在"里有的不再列），按结束时间从新到旧分页读（分段见 `PiHistorySection`）。
/// 两部分用同一个搜索词与项目范围（`Workspace.projectScope`）。
nonisolated struct PiSessionList: Sendable, Equatable {
    static let pageSize = 40

    /// 搜索词与项目范围：两部分共用。
    struct Filter: Hashable, Sendable {
        var text: String
        var project: UUID?
    }

    /// 重读的条件：筛选、分页读到第几条，与此刻（到点、同步通断时次序与"没能送达"随之变，`AppServices.speech`）。
    struct Key: Equatable {
        var filter: Filter
        var limit: Int
        var moment: Speech.Moment
    }

    var filter: Filter
    var now: [PiSessionListItem]
    /// 读到的历史（前 `limit` 条）与一共几条。
    var ended: [PiSessionListItem]
    var endedTotal: Int
    /// 在线会话此刻要显示的那次结束到哪了（按记录 id，`DeliveryRequest.shownEnd`）：正在结束、没能结束。会话页读同一条规则。
    var ends: [UUID: Speech.Trip] = [:]

    var loaded: Int { ended.count }
    /// 还有没读的历史。
    var hasMore: Bool { ended.count < endedTotal }
    /// 一共几个会话（在线的加结束的）。
    var count: Int { now.count + endedTotal }
    var isEmpty: Bool { count == 0 }
    /// 卡上写所在的项目图标：看全部项目时；只看一个项目时顶栏已经说了。
    var showsPlace: Bool { filter.project == nil }

    static func read(
        text: String, project: UUID? = nil, historyLimit: Int, at moment: Speech.Moment, from store: isolated CueStore
    ) throws -> PiSessionList {
        let live = try store.piSessionPage(PiSessionQuery(scope: .current, text: text, project: project, limit: .max)).items
            .filter { $0.isCurrent(at: moment) }
        let deliveries = Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
        let now = PiSessionState.inListOrder(live, state: \.state, deliveries: deliveries, cue: try store.cueDuty(), at: moment)
        let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, project: project, limit: historyLimit))
        return PiSessionList(
            filter: Filter(text: text, project: project), now: now,
            ended: ended.items, endedTotal: ended.total,
            ends: try live.reduce(into: [:]) { ends, item in
                ends[item.id] = DeliveryRequest.shownEnd(in: try store.deliveryRequests(toSession: item.state.sessionID), at: moment)
            })
    }
}

/// 一个 Agent 会话的行（iOS 的会话页与搜索页，Mac 的会话页、菜单栏面板、⌘K、项目页、Cue 页头面板同一种，状态都经 `PiShown`）。
/// - 整页（`page`）是一张两行的圆角卡片：第一行状态标、名字、哪家 Agent 的标志，右边所在项目的图标（看全部项目时）与时长；
///   第二行状态词接一句现在到哪了（此刻的短词优先，如没能结束、有草稿，见 `PiRowFacts.note`；没有时是 `PiProgress.note`，与项目页、任务看板同一句），
///   快满的上下文靠右。模型与子代理名单不上卡（在会话页里）。要你看的三种状态卡片换成这种状态的淡底（`PiShown.wash`）。
///   已结束的（历史）没有状态标与状态词，第二行是最后一句回答的首句（`PiProgress.line`），没有时是所在的文件夹；
///   都没有也留着这一行：张张卡一样高，长列表扫下去节奏不断。
/// 名字后是哪家 Agent 只放标志（`AgentMark`）：名字优先，窄处先截名字，标志与时长一直留着。
/// - 窄处（`compact`：Mac 菜单栏、⌘K、项目页、Cue 页头面板）两层：状态标、名字、时长；状态词接读数（`PiStatusLine`），上下文靠右。
/// 状态标自成一列（固定宽、对着名字那一行的中线），第二层从名字起头；上下文只在快满时出现（`PiRowFacts.context`），
/// 两种都在第二层落在时长正下方，与时长一样用等宽数字，状态词长短不同也不挪。
/// 时长只有一种写法：在这个状态里待了多久（`PiClock.Style.span`）。搜索命中在说过的话里时，第二层换成命中的那一截。
struct PiSessionRow: View {
    let session: PiSessionState
    /// 所在的项目；只看一个项目时调用方不给（整页卡片不再放它的图标）。
    let project: Project?
    /// 发给它的最近一条投送请求（显示状态见 `PiDelivery`）。
    let delivery: DeliveryRequest?
    var end: Speech.Trip?
    /// 发给它的最近一条改名（`PiSessionListItem.rename`）：名字与"正在改名""没能改名"由它推出（`PiRename`）。
    var rename: DeliveryRequest?
    /// 没能送达的话有几句（`PiSessionListItem.undelivered`）：你看过以后整行不再是"没能送达"，但只要还有，时长前留一个
    /// 胭脂的小折回箭头（读屏念"N 句没送到"），与会话页顶栏同一个数（`PiChat.undeliveredNote`）。
    let undelivered: Int
    var style = Style.compact
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.searchHighlight) private var highlight

    /// 密度与字号：整页列表（Agent 页）是 `page`（卡片），侧栏、面板、⌘K、项目页这些窄处是 `compact`。
    struct Style {
        var name: Font
        var line: Font
        /// 右上的时长、整页的所在与读数。
        var meta: Font
        /// 状态标的基准直径（外框是它的 1.8 倍）。
        var dot: CGFloat
        var spacing: CGFloat
        /// 整页：一张卡片。
        var card = false

        static let page = Style(name: Typography.bodyStrong, line: Typography.secondary, meta: Typography.meta, dot: 11, spacing: 4, card: true)
        static let compact = Style(name: Typography.body, line: Typography.meta, meta: Typography.meta, dot: 6, spacing: 1)
    }

    var body: some View {
        let shown = workspace.shown(session, delivery: delivery)
        let facts = services.settings.facts(session, shown: shown, end: end, rename: rename, at: services.speech)
        Group {
            if style.card {
                card(shown: shown, facts: facts)
            } else {
                compact(shown: shown, facts: facts)
            }
        }
        .relayArrival(session: session.sessionID)
    }

    /// 历史里的行：已结束、也不在唤醒（正在唤醒的照在线的写状态）。
    private var ended: Bool { session.state == .known(.ended) && !session.isWaking(by: delivery, at: services.speech) }

    private func card(shown: PiShown, facts: PiRowFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !ended { PiStateDot(shown: shown, size: style.dot).relaySpot(session: session.sessionID) }
            VStack(alignment: .leading, spacing: style.spacing) {
                headline(shown: shown)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let searchHit {
                        Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2)
                    } else if ended {
                        recap.foregroundStyle(palette.ink3)
                    } else {
                        // 状态词不截，后面那句先截
                        StateWord(shown: shown).fixedSize()
                        if let note = facts.note {
                            NoteWord(note: note)
                        } else if let progress = PiProgress.note(of: session, failure: nil) {
                            Text(progress).foregroundStyle(palette.ink2)
                        }
                    }
                    Spacer(minLength: 4)
                    if let context = facts.context { ContextFact(meter: context).font(style.meta).fixedSize() }
                }
                .font(style.line)
                .lineLimit(1)
            }
        }
        .contentTransition(.opacity)
        .animation(Motion.quick, value: shown)
        .animation(Motion.quick, value: facts)
        .sessionCard(wash: ended ? nil : shown.wash(palette))
        .accessibilityElement(children: .combine)
    }

    /// 历史卡的第二行：最后一句回答的首句，没有时是所在的文件夹；都没有是一个空格，占着这一行。
    private var recap: Text {
        if let reply = PiProgress.line(of: session) { return Text(reply) }
        if let folder = session.folder { return Text("\(Image(.folder)) \(folder)") }
        return Text(verbatim: " ")
    }

    private func compact(shown: PiShown, facts: PiRowFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: style.dot + 2) {
            PiStateDot(shown: shown, size: style.dot).relaySpot(session: session.sessionID)
            VStack(alignment: .leading, spacing: style.spacing) {
                headline(shown: shown)
                HStack(spacing: 6) {
                    if let searchHit {
                        Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2).lineLimit(1)
                    } else {
                        PiStatusLine(shown: shown, facts: facts)
                    }
                    Spacer(minLength: 4)
                    if let context = facts.context { ContextFact(meter: context).fixedSize() }
                }
                .font(style.line)
            }
            .contentTransition(.opacity)
            .animation(Motion.quick, value: shown)
            .animation(Motion.quick, value: facts)
        }
        .accessibilityElement(children: .combine)
    }

    /// 第一层：名字（有新回复时加粗）、Agent 标志、没送到的折回箭头、整页卡片所在项目的图标、右上的时长。
    private func headline(shown: PiShown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Highlight.matches(PiRename.title(of: session, request: rename, at: services.speech), highlight))
                .font(style.name).fontWeight(shown.isUnread ? .bold : nil)
                .foregroundStyle(style.card && ended ? palette.ink2 : palette.ink).lineLimit(1)
            // 是哪家 Agent：只放标志，名字优先（`AgentMark`）；名字先截断，标志一直留着
            if session.agentMark != nil { AgentMark(session: session, font: style.meta, named: false).fixedSize() }
            Spacer(minLength: 4)
            if shown.undelivered == nil, let unsent = PiChat.undeliveredNote(undelivered) {
                PiStateGlyph.undelivered.font(style.meta.weight(.semibold))
                    .accessibilityHidden(false).accessibilityLabel(unsent)
            }
            if style.card, let project { ProjectGlyph(project: project, size: Self.placeIcon).accessibilityLabel("在 \(project.name)") }
            // 时间只占它要的宽度，名字拿剩下的
            PiElapsed(shown: shown, font: style.meta, style: .span).fixedSize()
        }
    }

    private static let placeIcon: CGFloat = 12

    /// 搜索时名字、所在都没命中、而命中在说过的话里：第二层换成那句话从命中处前几个字起的一截，看得出为什么搜到它
    /// （会话搜索也查说过的话）。
    private var searchHit: String? {
        let terms = highlight.split(whereSeparator: \.isWhitespace)
        let hits = { (text: String?) in text.map { text in terms.contains { text.localizedCaseInsensitiveContains($0) } } ?? false }
        guard !terms.isEmpty, !hits(session.title), !hits(project?.name ?? session.folder),
              let prompt = (session.pendingPrompt ?? session.lastPrompt)?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
              let hit = terms.lazy.compactMap({ prompt.range(of: $0, options: .caseInsensitive) }).first else { return nil }
        let start = prompt.index(hit.lowerBound, offsetBy: -Self.leadIn, limitedBy: prompt.startIndex) ?? prompt.startIndex
        return "你说：\(start == prompt.startIndex ? "" : "…")\(prompt[start...])"
    }

    /// 截说过的话时命中处前面留几个字。
    private static let leadIn = 6
}

/// 行只随自己的数据重算（调用处挂 .equatable()）：会话列表里一个会话的状态变了，别的行不必再排一遍。
extension PiSessionRow: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.session == b.session && a.project == b.project && a.delivery == b.delivery && a.end == b.end && a.rename == b.rename
            && a.undelivered == b.undelivered && a.style.card == b.style.card && a.style.dot == b.style.dot
    }
}

/// Agent 页的一张会话卡片：留白、纸色圆角面，要你看的状态换成这种状态的淡底（`PiShown.wash`），
/// 换状态时淡入淡出。静态内容卡：不加阴影与描边，靠纸比桌面亮一档分层。
struct SessionCard: ViewModifier {
    var wash: Color?
    @Environment(\.palette) private var palette

    static let radius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        content
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(wash ?? palette.paper)
                    .animation(Motion.quick, value: wash)
            }
    }
}

extension View {
    func sessionCard(wash: Color? = nil) -> some View { modifier(SessionCard(wash: wash)) }
}

/// 状态词：带色的状态与状态标同色、加粗一档（`PiShown.labelTint`）。
private struct StateWord: View {
    let shown: PiShown
    @Environment(\.palette) private var palette

    var body: some View {
        Text(shown.label).fontWeight(shown.isColored ? .semibold : .medium).foregroundStyle(shown.labelTint(palette))
    }
}

/// 状态词后此刻的短词（`PiRowFacts.Note`）：没能结束、没能改名是胭脂。
private struct NoteWord: View {
    let note: PiRowFacts.Note
    @Environment(\.palette) private var palette

    var body: some View { Text(note.text).foregroundStyle(note.isFailure ? palette.failure : palette.ink2) }
}

/// 窄处的子代理：分叉图标接在跑 / 共几个（在跑的数是靛青）。
private struct SubagentCount: View {
    let summary: PiSubagentSummary
    @Environment(\.palette) private var palette

    var body: some View {
        let running = Text("\(summary.running)").foregroundStyle(summary.running > 0 ? palette.signature : palette.ink2).fontWeight(.semibold)
        Text("\(Image(.branch))\u{2009}\(running)/\(summary.total)")
            .monospacedDigit().foregroundStyle(palette.ink2)
            .accessibilityLabel(Dotted(summary.lead, summary.tail, summary.failure).spoken)
    }
}

/// 窄处的状态一行：状态色的状态词 → 此刻的短词 → 子代理在跑 / 共几个。放不下的从后往前整项丢掉（`FactsLayout`）。字号由外面给。
private struct PiStatusLine: View {
    let shown: PiShown
    let facts: PiRowFacts

    var body: some View {
        FactsLayout {
            StateWord(shown: shown).fact()
            if let note = facts.note { NoteWord(note: note).fact() }
            if let subagents = facts.subagents { SubagentCount(summary: subagents).fact() }
        }
        .lineLimit(1)
    }
}

/// 上下文读数："上下文 82%"，与回复框上的用量胶囊同一个说法（不画小图形的理由见 `PiContextGauge`）。行上只有快满的才有（`PiRowFacts.context`）：
/// 百分比加粗，七成起墨色，九成起胭脂。
private struct ContextFact: View {
    let meter: PiContextMeter
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = meter.level == .critical ? palette.failure : palette.ink
        Text("\(Text("上下文").foregroundStyle(palette.ink3)) \(Text(meter.percent).foregroundStyle(tint).fontWeight(.semibold))")
            .monospacedDigit()
            .accessibilityLabel(meter.help.spoken)
    }
}

/// 读数一行的排法：按顺序排，第一项（状态词）总在、放不下就截断；其余每项放得下整项才排，放不下的连同后面的都不排
/// （宽给到 0、裁掉：看不见，读屏照样读到）。
/// 每次排版各量一次理想宽度，不像 `ViewThatFits` 那样把每种排法都试排一遍。
private struct FactsLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let full = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: min(proposal.width ?? full, full), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, fits = true
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            let room = bounds.maxX - x
            let width = !fits ? 0 : ideal.width <= room + 0.5 ? ideal.width : index == 0 ? max(room, 0) : 0
            if index > 0, width == 0 { fits = false }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: ideal.height))
            if width > 0 { x += width + spacing }
        }
    }
}

private extension View {
    /// 读数一行里的一项：能被排成 0 宽并裁掉（`FactsLayout`）。
    func fact() -> some View { frame(minWidth: 0, alignment: .leading).clipped() }
}

/// 会话行长按（Mac 右键）菜单里的"标为未读"：做完一轮停着、你看过了的会话才有（`PiUnread.canMarkUnread`）；
/// 标了之后它回到"有新回复"（石绿铃铛），直到你再打开它。
struct MarkUnreadButton: View {
    let session: PiSessionState
    @Environment(AppServices.self) private var services

    var body: some View {
        if services.settings.canMarkUnread(session) {
            Button("标为未读", icon: .markUnread) { services.settings.markUnread(session) }
        }
    }
}
