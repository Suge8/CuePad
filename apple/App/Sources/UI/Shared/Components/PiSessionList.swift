import CueStore
import SwiftUI

/// 会话页读到的会话（Mac 与手机同一份）："现在"是全部在线的与正在唤醒的（`PiSessionListItem.isCurrent`；不多，不分页），按要你注意的先后；
/// "历史"是已结束的（"现在"里有的不再列），从新到旧。不筛也不搜时整页按项目分组（`History.grouped`：每组它在线的与最近结束的几条），
/// 按项目（或未分类）筛着、或在搜时按时间分页（`History.paged`，分段见 `PiHistorySection`）：搜到的要一条不落，按组截断就漏了。两部分用同一个搜索词与项目筛选。
nonisolated struct PiSessionList: Sendable, Equatable {
    static let pageSize = 40
    /// 分组时每组列出的最近结束的会话条数；更多的点组头的"全部"按这个项目筛。
    static let groupHead = 3

    /// 搜索词与项目筛选：两部分共用。
    struct Filter: Hashable, Sendable {
        var text: String
        var project: PiSessionProject?
    }

    /// 重读的条件：筛选、分页读到第几条，与此刻（到点、同步通断时次序与"没能送达"随之变，`AppServices.speech`）。
    struct Key: Equatable {
        var filter: Filter
        var limit: Int
        var moment: Speech.Moment
    }

    /// 历史的两种样子，由筛选与搜索词定：都没有时按项目分组，否则按时间分页（读到的前几条与一共几条）。
    enum History: Sendable, Equatable {
        case grouped([Group])
        case paged([PiSessionListItem], total: Int)
    }

    /// 按项目分的一组：项目（未分类时没有）、它在线的会话（"现在"的次序）、最近结束的几条与一共结束了几条。
    struct Group: Identifiable, Sendable, Equatable {
        let place: PiSessionProject
        let project: Project?
        let now: [PiSessionListItem]
        let ended: [PiSessionListItem]
        let endedTotal: Int
        var id: PiSessionProject { place }
        /// 结束的还有没列出来的：组头写"全部 N 个"。
        var hasMore: Bool { endedTotal > ended.count }
    }

    var filter: Filter
    var now: [PiSessionListItem]
    var history: History
    /// 能按它筛的项目：在 Mac 上绑了文件夹的（会话按工作目录归入项目，没绑的不会有会话）。
    var projects: Set<UUID>
    /// 在线会话此刻要显示的那次结束到哪了（按记录 id，`DeliveryRequest.shownEnd`）：正在结束、没能结束。会话页读同一条规则。
    var ends: [UUID: Speech.Trip] = [:]

    /// 按时间分页读到的历史（分组时为空）。
    var ended: [PiSessionListItem] { if case .paged(let items, _) = history { items } else { [] } }
    var loaded: Int { ended.count }
    /// 分页时还有没读的历史。
    var hasMore: Bool { if case .paged(let items, let total) = history { items.count < total } else { false } }
    /// 一共几个会话（在线的加结束的）。
    var count: Int {
        switch history {
        case .grouped(let groups): now.count + groups.reduce(0) { $0 + $1.endedTotal }
        case .paged(_, let total): now.count + total
        }
    }
    var isEmpty: Bool { count == 0 }
    /// 卡上写所在（项目或文件夹）：按时间平铺、又不是只看一个项目时；分组时组头、筛着时筛选已经说了。
    var showsPlace: Bool { if case .paged = history { filter.project == nil } else { false } }

    static func read(
        text: String, project: PiSessionProject? = nil, historyLimit: Int, at moment: Speech.Moment, from store: isolated CueStore
    ) throws -> PiSessionList {
        let live = try store.piSessionPage(PiSessionQuery(scope: .current, text: text, project: project, limit: .max)).items
            .filter { $0.isCurrent(at: moment) }
        let deliveries = Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
        let order = Dictionary(uniqueKeysWithValues: PiSessionState.inListOrder(live.map(\.state), deliveries: deliveries, cue: try store.cueDuty(), at: moment).enumerated().map { ($1.id, $0) })
        let now = live.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }
        let history: History
        if project == nil, text.trimmingCharacters(in: .whitespaces).isEmpty {
            let ended = try store.piSessionGroups(PiSessionQuery(scope: .ended, text: text), each: groupHead)
            history = .grouped(groups(now: now, ended: ended, order: try store.projects().map(\.id)))
        } else {
            let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, project: project, limit: historyLimit))
            history = .paged(ended.items, total: ended.total)
        }
        return PiSessionList(
            filter: Filter(text: text, project: project), now: now, history: history,
            projects: Set(try store.directoryBindings().map(\.projectID)),
            ends: try live.reduce(into: [:]) { ends, item in
                ends[item.id] = DeliveryRequest.shownEnd(in: try store.deliveryRequests(toSession: item.state.sessionID), at: moment)
            })
    }

    /// 在线的按所在分组、接上各组最近结束的；正在唤醒的已列在"现在"，历史里不再列。
    /// 组的次序：有在线会话的在前，各自照项目在侧栏的次序（`order`），未分类排在最后。
    private static func groups(now: [PiSessionListItem], ended: [PiSessionProject: PiSessionPage], order: [UUID]) -> [Group] {
        let current = Set(now.map(\.id))
        let live = Dictionary(grouping: now) { PiSessionProject($0.project?.id) }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { (PiSessionProject.project($1), $0) })
        return Set(live.keys).union(ended.keys).map { place in
            let history = ended[place]
            let items = live[place] ?? []
            return Group(
                place: place, project: (items + (history?.items ?? [])).lazy.compactMap(\.project).first, now: items,
                ended: history?.items.filter { !current.contains($0.id) } ?? [], endedTotal: history?.total ?? 0)
        }
        .filter { !$0.now.isEmpty || !$0.ended.isEmpty }
        .sorted { ($0.now.isEmpty ? 1 : 0, rank[$0.place] ?? .max) < ($1.now.isEmpty ? 1 : 0, rank[$1.place] ?? .max) }
    }
}

/// 一个 Agent 会话的行（iOS 的 Agent 页，Mac 的 Agent 页、菜单栏面板、项目页的 Agent 栏、⌘K 同一种，状态都经 `PiShown`）。
/// 不写会话在说什么（那在会话页里），只写它是谁、在哪、什么状态、跑得怎样。
/// - 整页（`page`）是一张圆角卡片，"现在"的卡片：状态标、名字（Mac 在后台开的带"后台"小签）与右上的时长；
///   所在（项目图标与名字，没有项目时是文件夹；按项目筛着时不写）接状态词，上下文靠右；有模型或子代理时再一层读数——模型、
///   子代理（角色图标，颜色是它的状态，后接在跑 / 共几个）。卡片高随内容，没有读数不留空行。要你看的三种状态卡片换成这种状态的淡底（`PiShown.wash`）。
///   已结束的（历史）两层：名字与时长、所在，没有状态标。
/// 名字后是哪家 Agent 只放标志（`AgentMark`）：名字优先，窄处先截名字，标志与时长一直留着。
/// - 窄处（`compact`：Mac 菜单栏、⌘K、项目页）两层：状态标、名字、时长；状态词接读数（`PiStatusLine`），上下文靠右。
/// 状态标自成一列（固定宽、对着名字那一行的中线），第二层从名字起头；上下文只在快满时出现（`PiRowFacts.context`），
/// 两种都在第二层落在时长正下方，与时长一样用等宽数字，状态词长短不同也不挪。
/// 时长只有一种写法：在这个状态里待了多久（`PiClock.Style.span`）。搜索命中在说过的话里时，状态那一层换成命中的那一截。
struct PiSessionRow: View {
    let session: PiSessionState
    /// 所在的项目；按项目筛着时调用方不给（整页不再写所在）。
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
                    // 已结束的没有状态词：所在后面不留孤零零的分隔点
                    if let place { place; if searchHit != nil || !ended { Dot() } }
                    if let searchHit {
                        Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2)
                    } else if !ended {
                        StateWord(shown: shown)
                        if let note = facts.note { Dot(); NoteWord(note: note) }
                    }
                    Spacer(minLength: 4)
                    if let context = facts.context { ContextFact(meter: context).font(style.meta).fixedSize() }
                }
                .font(style.line)
                .lineLimit(1)
                if facts.model != nil || facts.subagents != nil { FactColumns(facts: facts, font: style.meta) }
            }
        }
        .contentTransition(.opacity)
        .animation(Motion.quick, value: shown)
        .animation(Motion.quick, value: facts)
        .sessionCard(wash: ended ? nil : shown.wash(palette))
        .accessibilityElement(children: .combine)
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

    /// 第一层：名字（有新回复时加粗）、"后台"小签、没送到的折回箭头、右上的时长。
    private func headline(shown: PiShown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Highlight.matches(PiRename.title(of: session, request: rename, at: services.speech), highlight))
                .font(style.name).fontWeight(shown.isUnread ? .bold : nil)
                .foregroundStyle(style.card && ended ? palette.ink2 : palette.ink).lineLimit(1)
            // 是哪家 Agent：只放标志，名字优先（`AgentMark`）；名字先截断，标志一直留着
            if session.agentMark != nil { AgentMark(session: session, font: style.meta, named: false).fixedSize() }
            if style.card, session.hosted, !ended { HostedTag() }
            Spacer(minLength: 4)
            if shown.undelivered == nil, let unsent = PiChat.undeliveredNote(undelivered) {
                PiStateGlyph.undelivered.font(style.meta.weight(.semibold))
                    .accessibilityHidden(false).accessibilityLabel(unsent)
            }
            // 时间只占它要的宽度，名字拿剩下的
            PiElapsed(shown: shown, font: style.meta, style: .span).fixedSize()
        }
    }

    /// 整页的所在：项目图标与名字；没有项目（不是被筛掉）时是文件夹（会话名就以文件夹名开头时不重复，`PiPlace`）。都没有时不写。
    private var place: PlaceLine? {
        let folder = session.projectID == nil ? PiPlace.name(project: nil, folder: session.folder, besides: session.title) : nil
        guard project != nil || folder != nil else { return nil }
        return PlaceLine(project: project, folder: folder)
    }

    /// 搜索时名字、所在都没命中、而命中在说过的话里：状态那一层换成那句话从命中处前几个字起的一截，看得出为什么搜到它
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

/// Agent 页的一张会话卡片（会话、合成的"需要 /reload"）：留白、纸色圆角面，要你看的状态换成这种状态的淡底（`PiShown.wash`），
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

/// 子代理在跑 / 共几个（在跑的数是靛青）；窄处前面带一个分叉图标（`branch`），整页卡片后面接角色图标。
private struct SubagentCount: View {
    let summary: PiSubagentSummary
    var branch = false
    @Environment(\.palette) private var palette

    var body: some View {
        let running = Text("\(summary.running)").foregroundStyle(summary.running > 0 ? palette.signature : palette.ink2).fontWeight(.semibold)
        let icon = branch ? Text("\(Image(.branch))\u{2009}") : Text(verbatim: "")
        Text("\(icon)\(running)/\(summary.total)")
            .monospacedDigit().foregroundStyle(palette.ink2)
            .accessibilityLabel(Dotted(summary.lead, summary.tail, summary.failure).spoken)
    }
}

/// 整页卡片的所在：项目图标（项目色）与项目名，或文件夹图标与文件夹名。
private struct PlaceLine: View {
    let project: Project?
    let folder: String?
    @Environment(\.palette) private var palette
    @Environment(\.searchHighlight) private var highlight

    var body: some View {
        HStack(spacing: 4) {
            if let project {
                ProjectGlyph(project: project, size: Self.icon)
                Text(Highlight.matches(project.name, highlight)).foregroundStyle(palette.ink2)
            } else if let folder {
                Image(.folder).font(.system(size: Self.icon - 1, weight: .medium)).foregroundStyle(palette.ink3).frame(width: Self.icon + 6)
                    .accessibilityHidden(true)
                Text(Highlight.matches(folder, highlight)).foregroundStyle(palette.ink3)
            }
        }
    }

    private static let icon: CGFloat = 11
}

/// 整页卡片名字后的"后台"小签：Mac 在后台替你开着的会话（没有终端可跳）。
private struct HostedTag: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Text("后台").font(Typography.caption2.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(palette.fill, in: .capsule)
            .fixedSize()
    }
}

/// 整页卡片的读数一层（有模型或子代理时才有）：模型一列固定宽、子代理接在后面，卡片之间上下对齐；没有模型时那一列空着。
private struct FactColumns: View {
    let facts: PiRowFacts
    let font: Font
    @Environment(\.palette) private var palette
    @ScaledMetric private var modelWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 10) {
            (facts.model.map { BrandMark.label($0.mark, $0.name) } ?? Text(verbatim: "")).foregroundStyle(palette.ink2).frame(width: modelWidth, alignment: .leading)
                .accessibilityLabel(facts.model.map { "模型 \($0.name)" } ?? "")
            if let subagents = facts.subagents { SubagentRoster(summary: subagents) }
            Spacer(minLength: 0)
        }
        .font(font)
        .lineLimit(1)
    }
}

/// 子代理：在跑 / 共几个，后接角色图标（最多 `shown` 个，在跑、失败的排前面），颜色是它的状态——靛青在跑、胭脂失败、灰做完或空闲。
/// 窄卡片放不下时裁掉靠后的图标，数字总在。
private struct SubagentRoster: View {
    let summary: PiSubagentSummary
    @Environment(\.palette) private var palette

    private static let shown = 4

    var body: some View {
        HStack(spacing: 5) {
            SubagentCount(summary: summary).fixedSize().padding(.trailing, 2)
            ForEach(Array(summary.lineup.prefix(Self.shown).enumerated()), id: \.offset) { _, agent in
                Image(agent.roleIcon).imageScale(.small).foregroundStyle(color(agent)).accessibilityHidden(true)
            }
        }
        .frame(minWidth: 0, alignment: .leading).clipped()
    }

    private func color(_ agent: PiSubagentState) -> Color {
        agent.isRunning ? palette.signature : agent.phase == .known(.failed) ? palette.failure : palette.ink3
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
            if let subagents = facts.subagents { SubagentCount(summary: subagents, branch: true).fact() }
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

/// "现在"里的一行：一个会话，或两个以上需要 /reload 的会话（旧扩展，`PiShown.Status.restart`）合成的一行，点开再列出来。
/// 它们按 `PiShown.rank` 排在一起（工作中之后），所以合成的行落在原来那一段的位置。
enum PiNowRow<Item: Identifiable>: Identifiable {
    case session(Item)
    case reload([Item])

    var id: AnyHashable {
        switch self {
        case .session(let item): AnyHashable(item.id)
        case .reload: AnyHashable("reload")
        }
    }

    static func rows(_ items: [Item], state: (Item) -> PiSessionState) -> [PiNowRow] {
        let reload = items.filter { state($0).state == .known(.incompatible) }
        guard reload.count > 1 else { return items.map(PiNowRow.session) }
        var rows: [PiNowRow] = []
        for item in items {
            if state(item).state != .known(.incompatible) {
                rows.append(.session(item))
            } else if !rows.contains(where: { if case .reload = $0 { true } else { false } }) {
                rows.append(.reload(reload))
            }
        }
        return rows
    }
}

/// 合成的那一行："N 个会话需要 /reload"，点它展开或收起（展开的会话由调用方接在下面）。
struct PiReloadFold: View {
    let count: Int
    @Binding var expanded: Bool
    var style = PiSessionRow.Style.compact
    @Environment(\.palette) private var palette

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: style.dot + 2) {
                PiStateDot(shown: PiShown(status: .restart), size: style.dot)
                Text("\(count) 个会话需要 /reload").font(style.name).foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 4)
                Image(.forward).font(style.line.weight(.semibold)).foregroundStyle(palette.ink3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: expanded)
        .accessibilityExpanded(expanded)
        .accessibilityHint("旧版扩展的会话，在终端里对它们执行 /reload")
    }
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
