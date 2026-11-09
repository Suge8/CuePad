import Synchronization
import SwiftUI

/// 正在读的那一条：排版把读到的那一处挪了，就报出挪了多少，滚动区当场把可见区跟过去，正在读的不动。
/// 只按挪了多少补，不按记下时可见区在哪：读数常常把用户这一下滚动与排版的变化一起报上来，按位置补就把用户的滚动也退回去了。
/// 否决的方案：滚动位置按滚动目标认（`scrollPosition` 加 `scrollTargetLayout`）只保证那一段"还看得见"，段有几屏高，改宽时正在读的照样被推走；
/// 懒加载栈会保持最上面那条可见的视图，但它的总高与偏移按估计推，底部锚定会落在内容外（`ChatScroll` 头注释）；
/// 排版给的 `bounds` 原点不可靠（同一列有时按父视图的坐标、有时从 0 起），所以各层只记相对自己上沿的位置。
/// 记录在排版里写、在读数闭包（主线程）里读；排版不保证在主线程（动画由 SwiftUI 的渲染线程推进时，排版就在那条线程上跑），
/// 所以带锁，排版的回调也只捕获能跨线程的值；它不是状态，写它不触发更新。
nonisolated final class ChatAnchor: Sendable {
    struct Span: Equatable {
        let id: UUID
        let top: CGFloat
        let height: CGFloat
    }

    struct Tracked: Equatable {
        var shift: CGFloat = 0
        /// 挪动来自第几次排版（连着两次挪同样多也各报一次）；没挪为 0。
        var layout = 0
        var onScreen: Set<UUID> = []
    }

    private struct Mark {
        let run: Span
        let row: Span?
        let point: CGFloat
        let width: CGFloat
    }

    private struct Segment {
        var ids: [UUID] = []
        var rows: [Span] = []
        var height: CGFloat?
    }

    private struct State {
        var runs: [Span] = []
        var real: Set<UUID> = []
        var segments: [UUID: Segment] = [:]
        var width: CGFloat = 0
        var layout = 0
        var seen = 0
        var mark: Mark?
        /// 读到的那一处挪了、可见区还没跟过去的：一次更新里接连排几次版（拖窗口边）时读数 action 只拿到最后一次读数，各次的挪动攒在这里。
        var pending: CGFloat = 0
        /// 已经取走挪了、读数里还没反映出来的：系统一次更新里常把几次几何变化按同一份快照先后报上来，挪完之后到的那次读数还是挪之前的偏移，
        /// 按它认的话正在读的那一处就认错了（之后每次都按错的补）、越线也按没挪的位置报（贴底被误触发）。偏移变了就是反映出来了。
        var inFlight: CGFloat = 0
        var lastRead = CGFloat.nan
    }

    private let state = Mutex(State())

    func laid(runs: [Span], real: Set<UUID>, width: CGFloat) {
        state.withLock { state in
            for run in runs where real.contains(run.id) { state.segments[run.id, default: Segment()].height = run.height }
            guard runs != state.runs || real != state.real || width != state.width else { return }
            state.runs = runs
            state.real = real
            state.width = width
            state.layout += 1
        }
    }

    func laid(rows: [Span], of ids: [UUID]) {
        guard let run = ids.first else { return }
        state.withLock { state in
            guard state.segments[run]?.ids != ids || state.segments[run]?.rows != rows else { return }
            state.segments[run, default: Segment()].ids = ids
            state.segments[run, default: Segment()].rows = rows
            state.layout += 1
        }
    }

    func height(of run: UUID, ids: [UUID]) -> CGFloat? {
        state.withLock { state in state.segments[run].flatMap { $0.ids == ids ? $0.height : nil } }
    }

    /// 滚动区要跟过去的距离（取走就清掉）：按此刻攒下的取，不按某次读数报的——两次读数可能报着同一段挪动、各调一次 action，按读数取就跟了两遍。
    /// 先取再挪，挪动当场带来的那次读数才按挪好的位置认。
    func take() -> CGFloat {
        state.withLock { state in
            let shift = state.pending.rounded()
            state.pending -= shift
            state.inFlight += shift
            return shift
        }
    }

    /// `keeping` 为 false（贴着最新由底锚管、跳去了某一条由滚动区对准）时不攒挪动，只认此刻读到哪。
    func track(read: CGFloat, height: CGFloat, keeping: Bool) -> Tracked {
        state.withLock { state in
            if read != state.lastRead || !keeping { state.inFlight = 0 }
            state.lastRead = read
            if !keeping { state.pending = 0 }
            if keeping, state.layout != state.seen, let mark = state.mark, let now = Self.locate(mark, in: state) {
                state.pending += now - mark.run.top - mark.point
            }
            let top = read + state.inFlight + state.pending
            state.seen = state.layout
            state.mark = Self.mark(at: top, height: height, in: state)
            var tracked = Tracked(shift: (state.inFlight + state.pending).rounded(), onScreen: Self.onScreen(top, height, state))
            if tracked.shift != 0 { tracked.layout = state.layout }
            return tracked
        }
    }

    private static func onScreen(_ top: CGFloat, _ height: CGFloat, _ state: State) -> Set<UUID> {
        Set(state.runs.lazy.filter { $0.top < top + height && $0.top + $0.height > top }.map(\.id))
    }

    /// 那一段还是空白（刚滚进来，下一次更新才排成真的）时改认可见区里它下面第一段真的：空白换成真的之后段里各条怎么分布不知道，按空白对会差出它估高的那点出入。
    private static func mark(at top: CGFloat, height: CGFloat, in state: State) -> Mark? {
        guard let index = state.runs.firstIndex(where: { $0.top + $0.height > top }) else { return nil }
        let run = state.real.contains(state.runs[index].id)
            ? state.runs[index] : state.runs[index...].first { state.real.contains($0.id) && $0.top < top + height } ?? state.runs[index]
        let inside = top - run.top
        let row = state.real.contains(run.id) ? state.segments[run.id]?.rows.first { $0.top + $0.height > inside } : nil
        return Mark(run: run, row: row, point: inside, width: state.width)
    }

    /// 按那一条认而不是按段：它可能换了段（上面排开一批时最上面那段从更早的一条起、段首变了）。那一段此刻是空白也照记下的各条认：空白的高就是各条那次排出来的。
    private static func locate(_ mark: Mark, in state: State) -> CGFloat? {
        func scaled(_ offset: CGFloat, from old: CGFloat, to new: CGFloat) -> CGFloat {
            state.width != mark.width && offset > 0 && old > 0 ? offset * new / old : offset
        }
        if let old = mark.row, let run = state.runs.first(where: { state.segments[$0.id]?.ids.contains(old.id) == true }),
           let row = state.segments[run.id]?.rows.first(where: { $0.id == old.id }) {
            return run.top + row.top + scaled(mark.point - old.top, from: old.height, to: row.height)
        }
        return state.runs.first { $0.id == mark.run.id }.map { run in run.top + scaled(mark.point, from: mark.run.height, to: run.height) }
    }
}

/// 排版同 `VStack(alignment: .leading, spacing:)`，排的时候把各段的位置记进 `ChatAnchor`。
struct ChatStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.chatAnchor) private var anchor

    var body: some View {
        RecordingStack(spacing: spacing, laid: { [anchor] placed, width in
            var runs: [ChatAnchor.Span] = [], real: Set<UUID> = []
            for (subview, top, height) in placed {
                guard let tag = subview[ChatRun.self] else { continue }
                runs.append(ChatAnchor.Span(id: tag.id, top: top, height: height))
                if tag.real { real.insert(tag.id) }
            }
            anchor?.laid(runs: runs, real: real, width: width)
        }) {
            content
        }
    }
}

/// 一条一个子视图，按顺序对上 `ids`；排版同 `VStack(alignment: .leading, spacing:)`。
struct ChatRows<Content: View>: View {
    let ids: [UUID]
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.chatAnchor) private var anchor

    var body: some View {
        RecordingStack(spacing: spacing, laid: { [ids, anchor] placed, _ in
            anchor?.laid(rows: zip(ids, placed).map { ChatAnchor.Span(id: $0, top: $1.top, height: $1.height) }, of: ids)
        }) {
            content
        }
    }
}

private struct RecordingStack: Layout {
    let spacing: CGFloat
    let laid: @Sendable (_ placed: [(subview: LayoutSubview, top: CGFloat, height: CGFloat)], _ width: CGFloat) -> Void

    typealias Measured = (width: CGFloat?, heights: [CGFloat])

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) -> CGSize {
        let heights = heights(proposal.width, subviews, &cache)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? subviews.map { $0.sizeThatFits(proposal).width }.max() ?? 0
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) {
        var y: CGFloat = 0, placed: [(subview: LayoutSubview, top: CGFloat, height: CGFloat)] = []
        for (subview, height) in zip(subviews, heights(bounds.width, subviews, &cache)) {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            placed.append((subview, y, height))
            y += height + spacing
        }
        laid(placed, bounds.width)
    }

    func makeCache(subviews: Subviews) -> Measured { (nil, []) }

    func updateCache(_ cache: inout Measured, subviews: Subviews) { cache = (nil, []) }

    private func heights(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout Measured) -> [CGFloat] {
        if cache.heights.count != subviews.count || cache.width != width {
            cache = (width, subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height })
        }
        return cache.heights
    }
}

nonisolated struct ChatRun: LayoutValueKey, Equatable {
    let id: UUID
    let real: Bool

    static let defaultValue: ChatRun? = nil
}

extension EnvironmentValues {
    @Entry var chatAnchor: ChatAnchor?
    @Entry var chatOnScreen: Set<UUID> = []
}
