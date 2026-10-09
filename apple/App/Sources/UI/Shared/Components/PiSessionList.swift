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

/// 一个 Agent 会话的行（iOS 的 Agent 页，Mac 的 Agent 页、侧栏、菜单栏面板、项目页的 Agent 栏、⌘K 同一种，状态都经 `PiShown`）：
/// 整页（`page`）三行——状态标与名字、时长（`PiElapsed`）；在哪（项目或文件夹，按项目筛着时调用方不给项目） · 状态词 · 后台 · 你的话排队中；
/// 第三行（`PiRowLine`：结束进度、草稿、到哪了）。窄处（`compact`：Mac 侧栏、菜单栏、⌘K、项目页）两行——第二行是状态词接着第三行的内容。
/// 状态词只有要你动手的带色、有新回复加粗（`PiShown.labelTint`）。每行都占满固定的行数，什么都没有也留着高度，
/// 状态怎么变行高都不变；文字换时原地淡入淡出。已结束的整行更淡。
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
    struct Style {
        var name: Font
        var line: Font
        var dot: CGFloat
        var spacing: CGFloat
        /// 三行（整页）还是两行（窄处）。
        var full = false

        static let page = Style(name: .headline, line: .subheadline, dot: 8, spacing: 3, full: true)
        #if os(macOS)
        static let compact = Style(name: .system(size: 13, weight: .medium), line: .system(size: 11), dot: 6, spacing: 1)
        #else
        static let compact = Style(name: .body, line: .footnote, dot: 6, spacing: 1)
        #endif
    }

    var body: some View {
        let shown = services.settings.shown(session, delivery: delivery)
        let failure = PiRename.failure(rename, seen: services.settings.sessionSeen[session.sessionID]) ?? shown.undelivered(delivery)?.failure
        let line = searchHit ?? PiRowLine.of(session, draft: services.settings.draftPreview(for: session.id), end: end, failure: failure)
        let note = shown.note ?? (PiRename.isPending(rename) ? "正在改名" : nil)
        HStack(alignment: .firstTextBaseline, spacing: style.dot + 2) {
            PiStateDot(shown: shown, size: style.dot)
            VStack(alignment: .leading, spacing: style.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Highlight.matches(PiRename.title(of: session, request: rename), highlight)).font(style.name).fontWeight(shown.isUnread ? .semibold : nil).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    // 时间只占它要的宽度，名字拿剩下的
                    PiElapsed(shown: shown, font: style.line).fixedSize()
                }
                if style.full {
                    statusLine(shown, note: note)
                    text(of: line)
                } else {
                    // 两行：状态词接着第三行的内容（你的话在路上、正在改名时是它）
                    let rest = note.map { Text($0).foregroundStyle(palette.ink3) } ?? line.map(text(of:))
                    Text("\(status(shown))\(rest.map { Text("\(Text(" · ").foregroundStyle(palette.ink3))\($0)") } ?? Text(verbatim: ""))")
                }
            }
            .font(style.line)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(Motion.quick, value: shown)
            .animation(Motion.quick, value: line)
        }
        .accessibilityElement(children: .combine)
    }

    /// 搜索时名字、所在与进度都没命中、而命中在说过的话里：第三行换成那句话从命中处前几个字起的一截，看得出为什么搜到它
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

    /// 整页的第二行：在哪 · 状态词 · 后台 · 你的话排队中（或正在改名）。
    private func statusLine(_ shown: PiShown, note: String?) -> some View {
        let parts = [
            PiPlace.name(of: session, project: project).map { Text(Highlight.matches($0, highlight)).foregroundStyle(palette.ink3) },
            status(shown),
            session.hosted && session.state != .known(.ended) ? Text("后台").foregroundStyle(palette.ink3) : nil,
            note.map { Text($0).foregroundStyle(palette.ink3) },
        ].compactMap { $0 }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0)\(Text(" · ").foregroundStyle(palette.ink3))\($1)") }
    }

    /// 第三行：总是一个 Text（没有内容时是一个空格），一直占着一行；换内容时原地淡入淡出。
    private func text(of line: PiRowLine?) -> Text {
        switch line {
        case .ending: Text("正在结束…").foregroundStyle(palette.ink3)
        case .endFailed(let reason), .failed(let reason): Text(reason).foregroundStyle(palette.failure)
        case .draft(let draft): Text("\(Text("草稿").fontWeight(.semibold).foregroundStyle(palette.signature))  \(Text(draft).foregroundStyle(palette.ink2))")
        case .progress(let progress): Text(Highlight.matches(progress, highlight)).foregroundStyle(palette.ink2)
        case .hint(let hint): Text(hint).foregroundStyle(palette.ink3)
        case nil: Text(verbatim: " ")
        }
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
