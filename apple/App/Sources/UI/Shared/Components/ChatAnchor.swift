import Synchronization
import SwiftUI

/// 正在读的那一条（`ChatScroll` 持有，经 `chatAnchor` 交给对话）：各段在对话那一列里排在哪由 `ChatStack` 记，段里各条排在哪由 `ChatRows` 记，
/// 都在排版里写下。滚动区每次读数（`track`）按它认出可见区顶边落在哪一条、读到那一条的哪一处；之后排版把那一处挪了（它上面的空白段换成真的、
/// 改宽重排、上面排开了一批、最早的掉出去），就报出挪了多少，滚动区当场把可见区跟过去，正在读的不动。那一条自己因改宽变了高时按比例对回读到的那一处；
/// 宽没变时它变高矮是里面的内容变了（正在说的话长出来、展开了经过），读到的那一处离它顶边照旧。整屏都在空白里时按段对。
/// 同一份记录也给出哪几段在屏上、量过的段多高（`ChatSegments` 据此决定哪几段排真的、空白排多高），不给每段挂几何读数。
/// 位置都是对话那一列里的（从列的上沿算），可见区顶边按内容里的位置认：列上面只有不常变的一行（会话页"正在从 Mac 取对话"），它出没时会差这一行。
/// 只按挪了多少补，不按记下时可见区在哪：读数常常把用户这一下滚动与排版的变化一起报上来，按位置补就把用户的滚动也退回去了。
/// 否决的方案：滚动位置按滚动目标认（`scrollPosition` 加 `scrollTargetLayout`）只保证那一段"还看得见"，段有几屏高，改宽时正在读的照样被推走；
/// 懒加载栈会保持最上面那条可见的视图，但它的总高与偏移按估计推，底部锚定会落在内容外（`ChatScroll` 头注释）；
/// 排版给的 `bounds` 原点不可靠（同一列有时按父视图的坐标、有时从 0 起），所以各层只记相对自己上沿的位置。
/// 记录在排版里写、在读数闭包里读（不一定在主线程），所以带锁；它不是状态，写它不触发更新。
nonisolated final class ChatAnchor: Sendable {
    /// 一段或一条：相对上一层上沿的位置。
    struct Span: Equatable {
        let id: UUID
        let top: CGFloat
        let height: CGFloat
    }

    /// 排成真的时量到的高、段里是哪几条（空白沿用它）。
    struct Measured {
        let height: CGFloat
        let ids: [UUID]
    }

    /// 一次读数交给滚动区的：正在读的那一处挪了、可见区还没跟过去的距离（滚动区据它跑 action、`take` 取走）与在屏上的段。
    struct Tracked: Equatable {
        var shift: CGFloat = 0
        /// 挪动来自第几次排版（连着两次挪同样多也各报一次）；没挪为 0。
        var layout = 0
        var onScreen: Set<UUID> = []
    }

    /// 读到哪：那一段与段里那一条（段是空白时为 nil）当时的位置与高，读到的那一处在段顶边下多少（认的是下面那段时为负），当时列的宽。
    private struct Mark {
        let run: Span
        let row: Span?
        let point: CGFloat
        let width: CGFloat
    }

    private struct State {
        /// 列里的各段（`ChatStack`）、各段是哪几条、哪几段排成了真的，与各段里各条的位置（`ChatRows`，按段首那一条记）。
        var runs: [Span] = []
        var ids: [UUID: [UUID]] = [:]
        var real: Set<UUID> = []
        var rows: [UUID: (ids: [UUID], spans: [Span])] = [:]
        var measured: [UUID: Measured] = [:]
        var width: CGFloat = 0
        /// 排版每变一次加一；`seen` 是正在读的那一处按第几次认的。
        var layout = 0
        var seen = 0
        var mark: Mark?
        /// 读到的那一处挪了、可见区还没跟过去的：一次更新里接连排几次版（拖窗口边）时读数 action 只拿到最后一次读数，各次的挪动攒在这里。
        var pending: CGFloat = 0
    }

    private let state = Mutex(State())

    /// 列按宽 `width` 排好了（`ChatStack`）：各段的位置、各是哪几条、哪几段是真的。
    func laid(runs: [Span], ids: [UUID: [UUID]], real: Set<UUID>, width: CGFloat) {
        state.withLock { state in
            for run in runs where real.contains(run.id) { state.measured[run.id] = Measured(height: run.height, ids: ids[run.id] ?? []) }
            guard runs != state.runs || real != state.real || ids != state.ids || width != state.width else { return }
            state.runs = runs
            state.ids = ids
            state.real = real
            state.width = width
            state.layout += 1
        }
    }

    /// 一段里的各条排好了（`ChatRows`）：`ids` 是这一段排的是哪几条（据它认记下的是不是这一段此刻的样子），`rows` 是排出来的各条。
    func laid(rows: [Span], of ids: [UUID]) {
        guard let run = ids.first else { return }
        state.withLock { state in
            guard state.rows[run]?.ids != ids || state.rows[run]?.spans != rows else { return }
            state.rows[run] = (ids, rows)
            state.layout += 1
        }
    }

    func measured(_ run: UUID) -> Measured? { state.withLock { $0.measured[run] } }

    /// 滚动区要跟过去的距离（取走就清掉）：按此刻攒下的取，不按某次读数报的——两次读数可能报着同一段挪动、各调一次 action，按读数取就跟了两遍。
    /// 先取再挪，挪动当场带来的那次读数才按挪好的位置认。
    func take() -> CGFloat {
        state.withLock { state in
            let shift = state.pending.rounded()
            state.pending -= shift
            return shift
        }
    }

    /// 滚动区的一次读数：可见区顶边在内容里的 `read`、可见区高 `height`。排版变过就报出读到的那一处挪了多少，再按跟过去之后的位置重新认。
    /// `keeping` 为 false（贴着最新由底锚管、跳去了某一条由滚动区对准）时不攒挪动，只认此刻读到哪。
    func track(read: CGFloat, height: CGFloat, keeping: Bool) -> Tracked {
        state.withLock { state in
            if !keeping { state.pending = 0 }
            if keeping, state.layout != state.seen, let mark = state.mark, let now = Self.locate(mark, in: state) {
                state.pending += now - mark.run.top - mark.point
            }
            let top = read + state.pending
            state.seen = state.layout
            state.mark = Self.mark(at: top, height: height, in: state)
            var tracked = Tracked(shift: state.pending.rounded(), onScreen: Self.onScreen(top, height, state))
            if tracked.shift != 0 { tracked.layout = state.layout }
            return tracked
        }
    }

    private static func onScreen(_ top: CGFloat, _ height: CGFloat, _ state: State) -> Set<UUID> {
        Set(state.runs.lazy.filter { $0.top < top + height && $0.top + $0.height > top }.map(\.id))
    }

    /// 可见区顶边 `top` 落在的那一段、那一条（落在缝里取下面那个）。那一段还是空白（刚滚进来，下一次更新才排成真的）时改认可见区里它下面第一段真的：
    /// 空白换成真的之后段里各条怎么分布不知道，按空白对会差出它估高的那点出入。
    private static func mark(at top: CGFloat, height: CGFloat, in state: State) -> Mark? {
        guard let index = state.runs.firstIndex(where: { $0.top + $0.height > top }) else { return nil }
        let run = state.real.contains(state.runs[index].id)
            ? state.runs[index] : state.runs[index...].first { state.real.contains($0.id) && $0.top < top + height } ?? state.runs[index]
        let inside = top - run.top
        let row = state.real.contains(run.id) ? state.rows[run.id]?.spans.first { $0.top + $0.height > inside } : nil
        return Mark(run: run, row: row, point: inside, width: state.width)
    }

    /// 读到的那一处此刻在列里的位置：按那一条（它可能换了段：上面排开一批时最上面那段从更早的一条起、段首变了）；认不出那一条就按原来那一段；都不在了不补。
    /// 改了宽时读到的那一处在它里面的按它的高缩放，在它上面（认的是下面那段）照原样。那一段此刻是空白也照记下的各条认：空白的高就是各条那次排出来的。
    private static func locate(_ mark: Mark, in state: State) -> CGFloat? {
        func scaled(_ offset: CGFloat, from old: CGFloat, to new: CGFloat) -> CGFloat {
            state.width != mark.width && offset > 0 && old > 0 ? offset * new / old : offset
        }
        if let old = mark.row, let run = state.runs.first(where: { state.ids[$0.id]?.contains(old.id) == true }),
           let rows = state.rows[run.id], rows.ids == state.ids[run.id], let row = rows.spans.first(where: { $0.id == old.id }) {
            return run.top + row.top + scaled(mark.point - old.top, from: old.height, to: row.height)
        }
        return state.runs.first { $0.id == mark.run.id }.map { run in run.top + scaled(mark.point, from: mark.run.height, to: run.height) }
    }
}

/// 对话那一列（`ChatSegments` 用，同 `VStack(alignment: .leading, spacing:)`）：排的时候把各段的位置记进 `ChatAnchor`。
/// 每段一个子视图，带着所在段的标签（`ChatRun`）；不带标签的（最上面的"更早的 N 条"）只占位置。
struct ChatStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.chatAnchor) private var anchor

    var body: some View {
        RecordingStack(spacing: spacing, laid: { placed, width in
            var runs: [ChatAnchor.Span] = [], ids: [UUID: [UUID]] = [:], real: Set<UUID> = []
            for (subview, top, height) in placed {
                guard let tag = subview[ChatRun.self] else { continue }
                runs.append(ChatAnchor.Span(id: tag.id, top: top, height: height))
                ids[tag.id] = tag.ids
                if tag.real { real.insert(tag.id) }
            }
            anchor?.laid(runs: runs, ids: ids, real: real, width: width)
        }) {
            content
        }
    }
}

/// 一段里的各条（段的视图体用它排，同 `VStack(alignment: .leading, spacing:)`）：一条一个子视图，按顺序对上 `ids`，排的时候把各条在段里的位置记进 `ChatAnchor`。
struct ChatRows<Content: View>: View {
    let ids: [UUID]
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.chatAnchor) private var anchor

    var body: some View {
        RecordingStack(spacing: spacing, laid: { placed, _ in
            anchor?.laid(rows: zip(ids, placed).map { ChatAnchor.Span(id: $0, top: $1.top, height: $1.height) }, of: ids)
        }) {
            content
        }
    }
}

/// 竖排（同 `VStack(alignment: .leading, spacing:)`），摆完把各子视图相对自己上沿的位置与高、排的宽交给 `laid`。
private struct RecordingStack: Layout {
    let spacing: CGFloat
    let laid: (_ placed: [(subview: LayoutSubview, top: CGFloat, height: CGFloat)], _ width: CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGFloat]) -> CGSize {
        let heights = heights(proposal.width, subviews, &cache)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? subviews.map { $0.sizeThatFits(proposal).width }.max() ?? 0
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGFloat]) {
        var y: CGFloat = 0, placed: [(subview: LayoutSubview, top: CGFloat, height: CGFloat)] = []
        for (subview, height) in zip(subviews, heights(bounds.width, subviews, &cache)) {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            placed.append((subview, y, height))
            y += height + spacing
        }
        laid(placed, bounds.width)
    }

    func makeCache(subviews: Subviews) -> [CGFloat] { [] }

    func updateCache(_ cache: inout [CGFloat], subviews: Subviews) { cache = [] }

    /// 各子视图在宽 `width` 下的高；同一次排版里量高与摆放共用一次。
    private func heights(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout [CGFloat]) -> [CGFloat] {
        if cache.count != subviews.count + 1 || cache.last != width ?? -1 {
            cache = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height } + [width ?? -1]
        }
        return cache.dropLast()
    }
}

/// 子视图是哪一段、段里是哪几条、排的是不是真的（`ChatStack`）。
nonisolated struct ChatRun: LayoutValueKey, Equatable {
    let id: UUID
    let ids: [UUID]
    let real: Bool

    static let defaultValue: ChatRun? = nil
}

extension EnvironmentValues {
    /// 对话的排版记录与正在读的那一条（`ChatScroll` 给）。
    @Entry var chatAnchor: ChatAnchor?
    /// 在屏上的段（段首那一条，`ChatScroll` 按 `ChatAnchor` 的读数给）。
    @Entry var chatOnScreen: Set<UUID> = []
}
