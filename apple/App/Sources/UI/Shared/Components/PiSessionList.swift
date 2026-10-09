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
/// 整页（`page`）两层：状态标、名字、名字后小一号的所在（与"后台"）、右边时长；下面一句最要紧的话（`PiRowLine.lead`：
/// 问题、原因、在做什么、结果，没有时才是状态词）。状态由状态标的形状与颜色表达，不再重复写状态词。
/// 窄处（`compact`：Mac 侧栏、菜单栏、⌘K、项目页）两行——第二行是状态词接着那一句。
/// 颜色只给状态标与状态词（`PiShown.labelTint`），句子一律次要墨色；有新回复时名字加粗。每行都占满固定的行数，
/// 什么都没有也留着高度，状态怎么变行高都不变；文字换时原地淡入淡出。
struct PiSessionRow: View {
    let session: PiSessionState
    let project: Project?
    /// 发给它的最近一条投送请求（显示状态见 `PiDelivery`）。
    let delivery: DeliveryRequest?
    var end: DeliveryRequest?
    /// 发给它的最近一条改名（`PiSessionListItem.rename`）：名字与"正在改名""没能改名"由它推出（`PiRename`）。
    var rename: DeliveryRequest?
    var style = Style.compact
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.searchHighlight) private var highlight

    /// 密度与字号：整页列表（Agent 页）是 `page`，侧栏、面板、⌘K、项目页这些窄处是 `compact`。
    /// 整页的名字最重，下面那句是正文次墨，所在与时长是小一号的元信息。
    struct Style {
        var name: Font
        var line: Font
        /// 名字后的所在与右边的时长（整页）；窄处与第二行同一号。
        var meta: Font
        var dot: CGFloat
        var spacing: CGFloat
        /// 整页（名字后带所在、下面一句）还是窄处（状态词接着那一句）。
        var full = false

        static let page = Style(name: Typography.bodyStrong, line: Typography.secondary, meta: Typography.meta, dot: pageDot, spacing: 3, full: true)
        static let compact = Style(name: Typography.body, line: Typography.meta, meta: Typography.meta, dot: 6, spacing: 1)
        #if os(macOS)
        private static let pageDot: CGFloat = 8
        #else
        private static let pageDot: CGFloat = 9
        #endif
    }

    var body: some View {
        let shown = services.settings.shown(session, delivery: delivery)
        let failure = PiRename.failure(rename, seen: services.settings.sessionSeen[session.sessionID]) ?? shown.undelivered(delivery)?.failure
        let draft = services.settings.draftPreview(for: session.id)
        let note = shown.note ?? (PiRename.isPending(rename) ? "正在改名" : nil)
        HStack(alignment: .firstTextBaseline, spacing: style.dot + 2) {
            // 整页不写状态词，状态标就要说出它（读屏）
            PiStateDot(shown: shown, size: style.dot, announces: style.full, halo: style.full)
            VStack(alignment: .leading, spacing: style.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let name = Text(Highlight.matches(PiRename.title(of: session, request: rename), highlight)).font(style.name).fontWeight(shown.isUnread ? .semibold : nil).foregroundStyle(palette.ink).lineLimit(1)
                    if style.full, let place {
                        NameAndPlace {
                            name
                            // 放不下时宽度给到 0、裁掉：看不见，读屏照样读到
                            place.font(style.meta).foregroundStyle(palette.ink3).lineLimit(1)
                                .frame(minWidth: 0, alignment: .leading).clipped()
                        }
                    } else {
                        name
                    }
                    Spacer(minLength: 4)
                    // 时间只占它要的宽度，名字拿剩下的
                    PiElapsed(shown: shown, font: style.meta).fixedSize()
                }
                if style.full {
                    // 你的话在路上、正在改名时先写它（短），再接最要紧的那一句
                    let line = searchHit ?? PiRowLine.lead(session, shown: shown, draft: draft, end: end, failure: failure)
                    let lead = text(of: line, shown: shown)
                    // 拼成一个 Text 后读屏读不到分段点的替代，所以整句给读屏一个用"，"分段的标签
                    note.map {
                        Text("\(Text($0).foregroundStyle(palette.ink3))\(Text(" · ").foregroundStyle(palette.ink3))\(lead)")
                            .accessibilityLabel("\($0)，\(line.speech)")
                    } ?? lead
                } else {
                    let line = searchHit ?? PiRowLine.of(session, draft: draft, end: end, failure: failure)
                    let rest = note.map { Text($0).foregroundStyle(palette.ink3) } ?? line.map { text(of: $0, shown: shown) }
                    Text("\(status(shown))\(rest.map { Text("\(Text(" · ").foregroundStyle(palette.ink3))\($0)") } ?? Text(verbatim: ""))")
                        .accessibilityLabel([shown.label, note ?? line?.speech].compactMap { $0 }.joined(separator: "，"))
                }
            }
            .font(style.line)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(Motion.quick, value: shown)
            .animation(Motion.quick, value: draft)
        }
        .accessibilityElement(children: .combine)
    }

    /// 名字后的小字：所在（项目或文件夹，按项目筛着时调用方不给项目），Mac 在后台开的再写"后台"。
    private var place: Text? {
        let parts = [PiPlace.name(of: session, project: project), session.hosted && session.state != .known(.ended) ? "后台" : nil].compactMap { $0 }
        guard let first = parts.first else { return nil }
        let text = parts.dropFirst().reduce(Text(Highlight.matches(first, highlight))) { Text("\($0) · \(Text(Highlight.matches($1, highlight)))") }
        return text.accessibilityLabel(parts.joined(separator: "，"))
    }

    /// 搜索时名字、所在与进度都没命中、而命中在说过的话里：那一句换成那句话从命中处前几个字起的一截，看得出为什么搜到它
    /// （会话搜索也查说过的话）。
    private var searchHit: PiRowLine? {
        let terms = highlight.split(whereSeparator: \.isWhitespace)
        let hits = { (text: String?) in text.map { text in terms.contains { text.localizedCaseInsensitiveContains($0) } } ?? false }
        guard !terms.isEmpty, !hits(session.title), !hits(PiPlace.name(of: session, project: project)), !hits(PiProgress.line(of: session)),
              let prompt = (session.pendingPrompt ?? session.lastPrompt)?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
              let hit = terms.lazy.compactMap({ prompt.range(of: $0, options: .caseInsensitive) }).first else { return nil }
        let start = prompt.index(hit.lowerBound, offsetBy: -Self.leadIn, limitedBy: prompt.startIndex) ?? prompt.startIndex
        return .progress("你说：\(start == prompt.startIndex ? "" : "…")\(prompt[start...])")
    }

    /// 截说过的话时命中处前面留几个字。
    private static let leadIn = 6

    private func status(_ shown: PiShown) -> Text {
        Text(shown.label).fontWeight(shown.isUnread ? .semibold : shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
    }

    /// 那一句：总是一个 Text（没有内容时是一个空格），一直占着一行；换内容时原地淡入淡出。
    /// 原因、问题这些句子也是次要墨色：颜色已经在状态标上，整句上色会压过名字。
    private func text(of line: PiRowLine?, shown: PiShown) -> Text {
        switch line {
        case .ending: Text("正在结束…").foregroundStyle(palette.ink3)
        case .endFailed(let reason), .failed(let reason): Text(reason).foregroundStyle(palette.ink2)
        case .draft(let draft): Text("\(Text("草稿").fontWeight(.semibold).foregroundStyle(palette.ink))  \(Text(draft).foregroundStyle(palette.ink2))")
        case .progress(let progress): Text(Highlight.matches(progress, highlight)).foregroundStyle(palette.ink2)
        case .hint(let hint): Text(hint).foregroundStyle(palette.ink3)
        case .status: status(shown)
        case nil: Text(verbatim: " ")
        }
    }
}

/// 名字与名字后的所在：名字优先，放不下所在时只留名字（名字照常截断），不把所在挤成一两个字。
/// 每次排版各量一次两者的理想宽度就定下来，不像 `ViewThatFits` 那样把两种排法都试排一遍（长列表滚动时每行都在排）。
/// 对外的首行基线是名字的，与同一行的时长对齐。
private struct NameAndPlace: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let name = subviews[0].sizeThatFits(.unspecified), place = subviews[1].sizeThatFits(.unspecified)
        let full = name.width + spacing + place.width
        return CGSize(width: min(proposal.width ?? full, full), height: name.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let name = subviews[0], place = subviews[1]
        let nameSize = name.sizeThatFits(.unspecified), placeSize = place.sizeThatFits(.unspecified)
        let fits = nameSize.width + spacing + placeSize.width <= bounds.width + 0.5
        let nameProposal = ProposedViewSize(width: fits ? nameSize.width : bounds.width, height: nameSize.height)
        name.place(at: bounds.origin, proposal: nameProposal)
        let placeProposal = fits ? ProposedViewSize(placeSize) : ProposedViewSize(width: 0, height: placeSize.height)
        let baseline = name.dimensions(in: nameProposal)[.firstTextBaseline] - place.dimensions(in: placeProposal)[.firstTextBaseline]
        place.place(at: CGPoint(x: bounds.minX + (fits ? nameSize.width + spacing : bounds.width), y: bounds.minY + baseline), proposal: placeProposal)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        return subviews[0].dimensions(in: ProposedViewSize(width: bounds.width, height: nil))[guide]
    }
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
