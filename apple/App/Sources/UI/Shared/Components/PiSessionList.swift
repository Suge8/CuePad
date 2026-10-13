import CueStore
import SwiftUI

/// Agent 页读到的会话："现在"是全部在线的（不多，不分页），按要你注意的先后；"历史"是已结束的前 `loaded` 条，
/// 从新到旧（分段见 `PiHistorySection`）。两部分用同一个搜索词与项目筛选。
nonisolated struct PiSessionList: Sendable, Equatable {
    static let pageSize = 40

    /// 搜索词与项目筛选：两部分共用。
    struct Filter: Hashable, Sendable {
        var text: String
        var project: UUID?
    }

    struct Key: Equatable {
        var filter: Filter
        var limit: Int
    }

    var filter: Filter
    var now: [PiSessionListItem]
    var ended: [PiSessionListItem]
    var total: Int
    /// 能按它筛的项目：在 Mac 上绑了文件夹的（会话按工作目录归入项目，没绑的不会有会话）。
    var projects: Set<UUID>
    /// 在线会话此刻要显示的结束请求（按记录 id，`DeliveryRequest.shownEnd`）：正在结束、没能结束。会话页读同一条规则。
    var ends: [UUID: DeliveryRequest] = [:]

    var loaded: Int { ended.count }
    var isEmpty: Bool { now.isEmpty && total == 0 }

    static func read(text: String, project: UUID? = nil, historyLimit: Int, from store: isolated CueStore) throws -> PiSessionList {
        let live = try store.piSessionPage(PiSessionQuery(scope: .live, text: text, project: project, limit: .max)).items
        let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, text: text, project: project, limit: historyLimit))
        let deliveries = Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
        let order = Dictionary(uniqueKeysWithValues: PiSessionState.inListOrder(live.map(\.state), deliveries: deliveries).enumerated().map { ($1.id, $0) })
        return PiSessionList(
            filter: Filter(text: text, project: project), now: live.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }, ended: ended.items, total: ended.total,
            projects: Set(try store.directoryBindings().map(\.projectID)),
            ends: try live.reduce(into: [:]) { ends, item in
                ends[item.id] = DeliveryRequest.shownEnd(in: try store.deliveryRequests(toSession: item.state.sessionID))
            })
    }
}

/// 一个 Agent 会话的行（iOS 的 Agent 页，Mac 的 Agent 页、侧栏、菜单栏面板、项目页的 Agent 栏、⌘K 同一种，状态都经 `PiShown`）。
/// 不写会话在说什么（那在会话页里），只写它是谁、在哪、什么状态、跑得怎样。
/// - 整页（`page`）是一张圆角卡片，"现在"的卡片固定三层、一样高：状态标、名字（Mac 在后台开的带"后台"小签）与右上的时长；
///   所在（项目图标与名字，没有项目时是文件夹；按项目筛着时不写）接状态词；读数三列上下对齐——上下文（不知道时写"—"）、
///   会话的模型、子代理（角色图标，颜色是它的状态，后接在跑 / 共几个；没有时空着）。要你看的三种状态卡片铺一层很淡的状态色（`PiShown.wash`）。
///   已结束的（历史）两层：名字与时长、所在，没有状态标。
/// - 窄处（`compact`：Mac 侧栏、菜单栏、⌘K、项目页）两层：状态标、名字、时长；状态词接读数（`PiStatusLine`）。
/// 时长只有一种写法：在这个状态里待了多久（`PiClock.Wording.bare`）。搜索命中在说过的话里时，状态那一层换成命中的那一截。
struct PiSessionRow: View {
    let session: PiSessionState
    /// 所在的项目；按项目筛着时调用方不给（整页不再写所在）。
    let project: Project?
    /// 发给它的最近一条投送请求（显示状态见 `PiDelivery`）。
    let delivery: DeliveryRequest?
    var end: DeliveryRequest?
    /// 发给它的最近一条改名（`PiSessionListItem.rename`）：名字与"正在改名""没能改名"由它推出（`PiRename`）。
    var rename: DeliveryRequest?
    /// 没能送达的话有几句（`PiSessionListItem.undelivered`）：你看过以后整行不再是"没能送达"，但只要还有，时长前留一个
    /// 胭脂的小折回箭头（读屏念"N 句没送到"），与会话页顶栏同一个数（`PiChat.undeliveredNote`）。
    let undelivered: Int
    var style = Style.compact
    @Environment(AppServices.self) private var services
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
        /// 整页：一张卡片、三层。
        var card = false

        static let page = Style(name: Typography.bodyStrong, line: Typography.secondary, meta: Typography.meta, dot: 11, spacing: 4, card: true)
        static let compact = Style(name: Typography.body, line: Typography.meta, meta: Typography.meta, dot: 6, spacing: 1)
    }

    var body: some View {
        let shown = services.settings.shown(session, delivery: delivery)
        let facts = services.settings.facts(session, shown: shown, end: end, rename: rename)
        if style.card {
            card(shown: shown, facts: facts)
        } else {
            compact(shown: shown, facts: facts)
        }
    }

    private var ended: Bool { session.state == .known(.ended) }

    private func card(shown: PiShown, facts: PiRowFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !ended { PiStateDot(shown: shown, size: style.dot) }
            VStack(alignment: .leading, spacing: style.spacing) {
                headline(shown: shown)
                HStack(spacing: 6) {
                    if let place { place; Dot() }
                    if let searchHit {
                        Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2)
                    } else if !ended {
                        Text(shown.label).fontWeight(shown.isColored ? .semibold : .medium).foregroundStyle(shown.labelTint(palette))
                        if let note = facts.note {
                            Dot()
                            Text(note.text).foregroundStyle(note.isFailure ? palette.failure : palette.ink2)
                        }
                    }
                }
                .font(style.line)
                .lineLimit(1)
                if !ended { FactColumns(facts: facts, font: style.meta) }
            }
        }
        .contentTransition(.opacity)
        .animation(Motion.quick, value: shown)
        .animation(Motion.quick, value: facts)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SessionCard(wash: ended ? nil : shown.wash(palette)) }
        .accessibilityElement(children: .combine)
    }

    private func compact(shown: PiShown, facts: PiRowFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: style.dot + 2) {
            PiStateDot(shown: shown, size: style.dot)
            VStack(alignment: .leading, spacing: style.spacing) {
                headline(shown: shown)
                if let searchHit {
                    Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2).font(style.line).lineLimit(1)
                } else {
                    PiStatusLine(shown: shown, facts: facts).font(style.line)
                }
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
            Text(Highlight.matches(PiRename.title(of: session, request: rename), highlight))
                .font(style.name).fontWeight(shown.isUnread ? .bold : nil)
                .foregroundStyle(style.card && ended ? palette.ink2 : palette.ink).lineLimit(1)
            if style.card, session.hosted, !ended { HostedTag() }
            Spacer(minLength: 4)
            if shown.status != .delivery(.failed), let unsent = PiChat.undeliveredNote(undelivered) {
                Image(systemName: "arrow.uturn.backward").font(style.meta.weight(.semibold)).foregroundStyle(palette.failure)
                    .accessibilityLabel(unsent)
            }
            // 时间只占它要的宽度，名字拿剩下的
            PiElapsed(shown: shown, font: style.meta, wording: .bare).fixedSize()
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

/// Agent 页的会话卡片面：纸色圆角卡片，要你看的状态再铺一层很淡的状态色（`PiShown.wash`），换状态时淡入淡出。
/// 静态内容卡：不加阴影与描边，靠纸比桌面亮一档分层。
struct SessionCard: View {
    var wash: Color?
    @Environment(\.palette) private var palette

    static let radius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        shape.fill(palette.paper)
            .overlay { shape.fill(wash?.opacity(palette.dark ? 0.08 : 0.07) ?? .clear) }
            .animation(Motion.quick, value: wash)
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
                Image(systemName: "folder").font(.system(size: Self.icon - 1, weight: .medium)).foregroundStyle(palette.ink3).frame(width: Self.icon + 6)
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

/// 整页卡片的读数一层：三列固定宽、上下对齐——上下文、模型、子代理。不知道用量写"—"，没有模型、没有子代理时那一列空着，位置不动。
private struct FactColumns: View {
    let facts: PiRowFacts
    let font: Font
    @Environment(\.palette) private var palette
    @ScaledMetric private var contextWidth: CGFloat = 80
    @ScaledMetric private var modelWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 10) {
            ContextFact(meter: facts.context).frame(width: contextWidth, alignment: .leading)
            Text(facts.model ?? "").foregroundStyle(palette.ink2).frame(width: modelWidth, alignment: .leading)
                .accessibilityLabel(facts.model.map { "模型 \($0)" } ?? "")
            if let subagents = facts.subagents { SubagentRoster(summary: subagents) }
            Spacer(minLength: 0)
        }
        .font(font)
        .lineLimit(1)
    }
}

/// 子代理：在跑 / 共几个，后接角色图标（最多 `shown` 个，在跑、失败的排前面），颜色是它的状态——晴蓝在跑、胭脂失败、灰做完或空闲。
/// 窄卡片放不下时裁掉靠后的图标，数字总在。
private struct SubagentRoster: View {
    let summary: PiSubagentSummary
    @Environment(\.palette) private var palette

    private static let shown = 4

    var body: some View {
        HStack(spacing: 5) {
            Text("\(Text("\(summary.running)").foregroundStyle(summary.running > 0 ? palette.live : palette.ink2).fontWeight(.semibold))/\(summary.total)")
                .monospacedDigit().foregroundStyle(palette.ink2).fixedSize().padding(.trailing, 2)
            ForEach(Array(summary.lineup.prefix(Self.shown).enumerated()), id: \.offset) { _, agent in
                Image(systemName: agent.roleSymbol).imageScale(.small).foregroundStyle(color(agent))
            }
        }
        .frame(minWidth: 0, alignment: .leading).clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Dotted(summary.lead, summary.tail, summary.failure).spoken)
    }

    private func color(_ agent: PiSubagentState) -> Color {
        agent.isRunning ? palette.live : agent.phase == .known(.failed) ? palette.failure : palette.ink3
    }
}

/// 窄处的状态一行：状态色的状态词 → 此刻的短词 → 子代理在跑 / 共几个 → 上下文用了多少。放不下的从后往前整项丢掉（`FactsLayout`）。字号由外面给。
struct PiStatusLine: View {
    let shown: PiShown
    let facts: PiRowFacts
    @Environment(\.palette) private var palette

    var body: some View {
        FactsLayout {
            Text(shown.label).fontWeight(shown.isUnread ? .semibold : .medium).foregroundStyle(shown.labelTint(palette)).fact()
            if let note = facts.note {
                Text(note.text).foregroundStyle(note.isFailure ? palette.failure : palette.ink2).fact()
            }
            if let subagents = facts.subagents {
                Text("\(Image(systemName: "arrow.triangle.branch"))\u{2009}\(Text("\(subagents.running)").foregroundStyle(subagents.running > 0 ? palette.live : palette.ink2).fontWeight(.semibold))/\(subagents.total)")
                    .monospacedDigit().foregroundStyle(palette.ink2)
                    .accessibilityLabel(Dotted(subagents.lead, subagents.tail, subagents.failure).spoken)
                    .fact()
            }
            if let context = facts.context { ContextFact(meter: context).fact() }
        }
        .lineLimit(1)
    }
}

/// 上下文读数："上下文 62%"，与回复框上的用量胶囊同一个说法（不画小图形的理由见 `PiContextGauge`）：七成起百分比墨色加粗，九成起胭脂；
/// 不知道（刚压缩完）时写"—"。
private struct ContextFact: View {
    let meter: PiContextMeter?
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = switch meter?.level {
        case .critical: palette.failure
        case .tight: palette.ink
        case .roomy, nil: palette.ink2
        }
        Text("\(Text("上下文").foregroundStyle(palette.ink3)) \(Text(meter?.percent ?? "—").foregroundStyle(meter == nil ? palette.ink3 : tint).fontWeight(meter.map { $0.level == .roomy ? nil : .semibold } ?? nil))")
            .monospacedDigit()
            .accessibilityLabel(meter?.help.spoken ?? "上下文用量还不知道")
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
                Image(systemName: "chevron.right").font(style.line.weight(.semibold)).foregroundStyle(palette.ink3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: expanded)
        .accessibilityValue(expanded ? "已展开" : "已收起")
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
            Button("标为未读", systemImage: "circle.fill") { services.settings.markUnread(session) }
        }
    }
}
