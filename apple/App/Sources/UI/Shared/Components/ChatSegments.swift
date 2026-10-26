import SwiftUI

/// 对话一段一段排（会话页 `PiConversation` 与 Cue 页共用，自己排成一列 `ChatStack`）：排 `window` 那么多条到最新，一段约 `size` 条；上面还有更早的时最上面一行"更早的 N 条"（`EarlierRow`）。
/// 段界只看条目自己，不看它排第几：id 的散列落在 `size` 分之一上的那条起一段，连着 `2 × size` 条没有这样的段界时补一处（从上一处段界数起）。
/// 所以对话怎么变都只动挨着变化的那一段：新的一条长在最新那段、上面再排开只是最上面那段变长或多出几段、最早的掉出读的范围
/// （Cue 页只读最近 `CueThread.limit` 条，来一句新的最早那条就掉出去）、中间回来一条（答完的拍板），别的段条目不变。
/// 按位置切的话最早那条一掉每段都往前挪一条，离屏空白按旧的高排，几十段的差加起来能有几屏，贴着最新时可见区落在内容外、整屏空白。
/// 段由 `segment` 排，交出来的要只按内容比较（`equatable()`）：没变的段不重算也不重排，系统直接用上次量好的尺寸。
///
/// 屏上的段、最新一段（还会长）、要跳去的那条所在的段（刻度滑条、Cue 页的第一条新消息），连同离它们不到 `spare` 段的，还有没量过或量过之后条目变了的段排真的：
/// 最新那头与要跳去的地方一直是真的，回到最新、跳过去落下的那一帧不露空白，不用等"到了屏上"的回报。
/// 哪几段在屏上、量过的段多高都出自排版的记录（`ChatAnchor`，`ChatStack` 排的时候记下，滚动区每次读数按可见区算出在屏上的段），不给每段挂几何读数，
/// 也不按系统的滚进滚出通知（`onScrollVisibilityChange`）：那个通知管的是在不在屏幕上，页一被盖住（回到列表、推入别的页）就报全都不在，
/// 回来时没再报或报晚了，除最新一段全是空白。
/// 其余换成量好的那么高的空白：挂着的视图数不随翻过的深度变多（整列都挂着时，翻到 300 轮前排开一段要 200ms 以上）。
/// 空白沿用最后一次实测的高，不按宽反比缩放：表格、代码、短行与留白不随宽反比变化，那样会把整列系统性地估高或估矮。
/// 改宽只重排挂着的段；空白换成真的时更新实测，正在读的不动由滚动区按那一条补（`ChatAnchor`），不为求离屏的准确高度重排全部历史。
/// 段的视图体用 `ChatRows` 排各条：它记下各条在段里的位置，滚动区才认得出正在读的是哪一条。
struct ChatSegments<Item: Identifiable, Segment: View>: View where Item.ID == UUID {
    let items: [Item]
    let window: ChatWindow
    let size: Int
    /// 条与条之间（与段里的 `ChatRows` 同一个）。
    let spacing: CGFloat
    /// 屏上那几段上下各再留几段真的：快甩时滑进来的先是排好的，不露空白；来回翻时离开不远的段不拆了又建。
    var spare = 1
    @ViewBuilder let segment: (ArraySlice<Item>) -> Segment
    /// 要跳去的那一条（`ChatColumn` 往列里给）。在这里读，不由放列的页传：页在列外，读不到。
    @Environment(\.chatTarget) private var target
    @Environment(\.chatAnchor) private var anchor
    @Environment(\.chatOnScreen) private var onScreen

    /// 一段：段首那一条、在 `items` 里的范围、从上往下第几段。
    private struct Run: Identifiable {
        let id: Item.ID
        let range: Range<Int>
        let index: Int
    }

    var body: some View {
        let from = max(0, items.count - window.count)
        let runs = Self.runs(items, size: size, from: from)
        let target = target.flatMap { id in items.firstIndex { $0.id == id } }
        let shown = runs.filter { run in
            run.index == runs.count - 1 || onScreen.contains(run.id) || target.map(run.range.contains) == true
        }.map(\.index)
        if !runs.isEmpty {
            ChatStack(spacing: spacing) {
                // 在列里排：它出没时列里的各段跟着上下挪，滚动区据此补（`ChatAnchor`）
                if from > 0 { EarlierRow(count: window.earlier, action: window.showEarlier) }
                ForEach(runs) { run in cell(run, real: shown.contains { abs($0 - run.index) <= spare }) }
            }
        }
    }

    private static func runs(_ items: [Item], size: Int, from: Int) -> [Run] {
        var runs: [Run] = [], start = from
        for index in from..<items.count where index > start && (index - start >= 2 * size || UInt(bitPattern: items[index].id.hashValue) % UInt(size) == 0) {
            runs.append(Run(id: items[start].id, range: start..<index, index: runs.count))
            start = index
        }
        if start < items.count { runs.append(Run(id: items[start].id, range: start..<items.count, index: runs.count)) }
        return runs
    }

    @ViewBuilder private func cell(_ run: Run, real: Bool) -> some View {
        let slice = items[run.range], ids = slice.map(\.id)
        if !real, let measured = anchor?.measured(run.id), measured.ids == ids {
            Color.clear.frame(height: measured.height)
                .layoutValue(key: ChatRun.self, value: ChatRun(id: run.id, ids: ids, real: false))
        } else {
            segment(slice).layoutValue(key: ChatRun.self, value: ChatRun(id: run.id, ids: ids, real: true))
        }
    }
}

/// 排开的最上面一行：还有更早的对话（居中的标记）。往上翻快到这里时会自动再排开一段（`ChatFollow.nearOldest`），点它（读屏）也能排开。
struct EarlierRow: View {
    /// 点一下再排开几条。
    let count: Int
    let action: () -> Void

    var body: some View {
        ChatMarker(action: action) { Label("更早的 \(count) 条", icon: .earlier).labelStyle(.titleAndIcon) }
    }
}
