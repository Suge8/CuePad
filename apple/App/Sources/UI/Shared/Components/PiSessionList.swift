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
    var style = Style.compact
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

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
        let line = PiRowLine.of(session, draft: services.settings.draftPreview(for: session.id), end: end)
        HStack(alignment: .firstTextBaseline, spacing: style.dot + 2) {
            PiStateDot(shown: shown, size: style.dot)
            VStack(alignment: .leading, spacing: style.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title).font(style.name).fontWeight(shown.isUnread ? .semibold : nil).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    PiElapsed(shown: shown, font: style.line)
                }
                if style.full {
                    statusLine(shown)
                    text(of: line)
                } else {
                    // 两行：状态词接着第三行的内容（你的话在路上时是它）
                    let rest = shown.note.map { Text($0).foregroundStyle(palette.ink3) } ?? line.map(text(of:))
                    Text("\(status(shown))\(rest.map { Text("\(Text(" · ").foregroundStyle(palette.ink3))\($0)") } ?? Text(verbatim: ""))")
                }
            }
            .font(style.line)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(Motion.quick, value: shown)
            .animation(Motion.quick, value: line)
        }
        .opacity(session.state == .known(.ended) ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private func status(_ shown: PiShown) -> Text {
        Text(shown.label).fontWeight(shown.isUnread ? .semibold : shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
    }

    /// 整页的第二行：在哪 · 状态词 · 后台 · 你的话排队中。
    private func statusLine(_ shown: PiShown) -> some View {
        let parts = [
            PiPlace.name(of: session, project: project).map { Text($0).foregroundStyle(palette.ink3) },
            status(shown),
            session.hosted && session.state != .known(.ended) ? Text("后台").foregroundStyle(palette.ink3) : nil,
            shown.note.map { Text($0).foregroundStyle(palette.ink3) },
        ].compactMap { $0 }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0)\(Text(" · ").foregroundStyle(palette.ink3))\($1)") }
    }

    /// 第三行：总是一个 Text（没有内容时是一个空格），一直占着一行；换内容时原地淡入淡出。
    private func text(of line: PiRowLine?) -> Text {
        switch line {
        case .ending: Text("正在结束…").foregroundStyle(palette.ink3)
        case .endFailed(let reason): Text(reason).foregroundStyle(palette.failure)
        case .draft(let draft): Text("\(Text("草稿").fontWeight(.semibold).foregroundStyle(palette.signature))  \(Text(draft).foregroundStyle(palette.ink2))")
        case .progress(let progress): Text(progress).foregroundStyle(palette.ink2)
        case .hint(let hint): Text(hint).foregroundStyle(palette.ink3)
        case nil: Text(verbatim: " ")
        }
    }
}
