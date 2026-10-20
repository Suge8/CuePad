import SwiftUI

/// 对话一段一段排（会话页 `PiConversation` 与 Cue 页共用，放在对话那一列的竖排里，与列里别的行同一层）：从第 `from` 条排到最新，一段约 `size` 条。
/// 段界只看条目自己，不看它排第几：id 的散列落在 `size` 分之一上的那条起一段，连着 `2 × size` 条没有这样的段界时补一处（从上一处段界数起）。
/// 所以对话怎么变都只动挨着变化的那一段：新的一条长在最新那段、上面再排开只是最上面那段变长或多出几段、最早的掉出读的范围
/// （Cue 页只读最近 `CueThread.limit` 条，来一句新的最早那条就掉出去）、中间回来一条（答完的"等你"），别的段条目不变。
/// 按位置切的话最早那条一掉每段都往前挪一条，离屏空白按旧的高排，几十段的差加起来能有几屏：正在读的被推走，贴着最新时可见区落在内容外、整屏空白。
/// 段由 `segment` 排，交出来的要只按内容比较（`equatable()`）：没变的段不重算也不重排，系统直接用上次量好的尺寸。
///
/// 屏上的段、最新一段（还会长）、要跳去的那条所在的段（刻度滑条、Cue 页的第一条新消息），连同离它们不到 `spare` 段的，还有没量过或量过之后条目变了的段排真的：
/// 最新那头与要跳去的地方一直是真的，回到最新、跳过去落下的那一帧不露空白，不用等"到了屏上"的回报。
/// 哪几段在屏上按段在滚动区可见范围里的几何算（`bounds(of: .scrollView)`），不按系统的滚进滚出通知（`onScrollVisibilityChange`）：
/// 那个通知管的是在不在屏幕上，页一被盖住（回到列表、推入别的页）就报全都不在，回来时全靠它再报一次才排回真的，
/// 没再报或报晚了，除最新一段全是空白——最新一条在，上面一大段白。几何只看段在滚动区里的位置，页盖没盖住都不变。
/// 其余换成量好的那么高的空白：挂着的视图数不随翻过的深度变多（整列都挂着时，翻到 300 轮前排开一段要 200ms 以上），内容高也不变，
/// 换的时候正在读的不动，滚动区不用补偿。宽（`width`，整列的宽，由放它的那一列量）变了（拖窗口、转屏），量过的高按宽反比估
/// （字一行排得越宽越矮），排成真的时再换成实测：不估就得把翻过的段全排一遍，翻到 200 轮前拖一下窗口边主线程要卡 1 秒以上。
struct ChatSegments<Item: Identifiable, Segment: View>: View where Item.ID == UUID {
    let items: [Item]
    let size: Int
    let from: Int
    let width: CGFloat
    /// 屏上那几段上下各再留几段真的：快甩时滑进来的先是排好的，不露空白；来回翻时离开不远的段不拆了又建。
    var spare = 1
    @ViewBuilder let segment: (ArraySlice<Item>) -> Segment
    /// 要跳去的那一条（`ChatColumn` 往列里给）。在这里读，不由放列的页传：页在列外，读不到。
    @Environment(\.chatTarget) private var target
    /// 量过的段，按段首那一条记。
    @State private var sizes: [Item.ID: Measured] = [:]
    /// 在屏上的段（段首那一条）。
    @State private var onScreen: Set<Item.ID> = []

    private struct Measured {
        let size: CGSize
        /// 量的时候这一段是哪几条。
        let ids: [Item.ID]
    }

    /// 一段：段首那一条、在 `items` 里的范围、从上往下第几段。
    private struct Run: Identifiable {
        let id: Item.ID
        let range: Range<Int>
        let index: Int
    }

    var body: some View {
        let runs = Self.runs(items, size: size, from: from)
        let target = target.flatMap { id in items.firstIndex { $0.id == id } }
        let shown = runs.filter { run in
            run.index == runs.count - 1 || onScreen.contains(run.id) || target.map(run.range.contains) == true
        }.map(\.index)
        ForEach(runs) { run in
            cell(run, real: shown.contains { abs($0 - run.index) <= spare })
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.bounds(of: .scrollView).map { CGRect(origin: .zero, size: proxy.size).intersects($0) } ?? false
                } action: { visible in
                    // 刚排开的一批段第一次都报"不在屏上"：不变就不写，免得多出一次更新、正赶上跳过去落下的那一帧
                    guard visible != onScreen.contains(run.id) else { return }
                    if visible { onScreen.insert(run.id) } else { onScreen.remove(run.id) }
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
        let slice = items[run.range]
        if !real, width > 0, let measured = sizes[run.id], measured.ids.elementsEqual(slice.lazy.map(\.id)) {
            Color.clear.frame(height: (measured.size.height * measured.size.width / width).rounded())
        } else {
            segment(slice)
                .onGeometryChange(for: CGSize.self) { CGSize(width: $0.size.width.rounded(), height: $0.size.height) } action: {
                    sizes[run.id] = Measured(size: $0, ids: slice.map(\.id))
                }
        }
    }
}
