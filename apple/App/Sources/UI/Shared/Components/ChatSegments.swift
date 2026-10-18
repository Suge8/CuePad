import SwiftUI

/// 对话一段一段排（会话页 `PiConversation` 与 Cue 页共用，放在对话那一列的竖排里，与列里别的行同一层）：从第 `first` 段排到最新，
/// 每段 `size` 条，段按从最早那条起的位置切，上面再排开一段只是多显示一段，已有的段不变。段由 `segment` 排，交出来的要只按内容比较
/// （`equatable()`）：下面来了一句、上面排开一段时，没变的段不重算也不重排，系统直接用上次量好的尺寸。
///
/// 屏上与离屏不到 `spare` 段的、最新一段（还会长）、`pinned` 的段（描圈的那条所在，刻度滑条正要跳过去）、还没量过的段排真的；
/// 其余换成量好的那么高的空白：挂着的视图数不随翻过的深度变多（整列都挂着时，翻到 300 轮前排开一段要 200ms 以上），内容高也不变，
/// 换的时候正在读的不动，滚动区不用补偿。宽（`width`，整列的宽，由放它的那一列量）变了（拖窗口、转屏），量过的高按宽反比估
/// （字一行排得越宽越矮），排成真的时再换成实测：不估就得把翻过的段全排一遍，翻到 200 轮前拖一下窗口边主线程要卡 1 秒以上。
struct ChatSegments<Item: Identifiable, Segment: View>: View {
    let items: [Item]
    let size: Int
    let first: Int
    let width: CGFloat
    /// 屏上那几段上下各再留几段真的：快甩时滑进来的先是排好的，不露空白；来回翻时离开不远的段不拆了又建。
    var spare = 1
    var pinned: (ArraySlice<Item>) -> Bool = { _ in false }
    @ViewBuilder let segment: (ArraySlice<Item>) -> Segment
    @State private var sizes: [Int: CGSize] = [:]
    @State private var onScreen: Set<Int> = []

    /// `count` 条切成几段。
    static func count(_ count: Int, size: Int) -> Int { (count + size - 1) / size }

    var body: some View {
        let last = Self.count(items.count, size: size) - 1
        ForEach(first..<(last + 1), id: \.self) { index in
            cell(index, last: last)
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    if visible { onScreen.insert(index) } else { onScreen.remove(index) }
                }
        }
    }

    @ViewBuilder private func cell(_ index: Int, last: Int) -> some View {
        let slice = items[(index * size)..<min((index + 1) * size, items.count)]
        if let measured = sizes[index], width > 0, index != last, !onScreen.contains(where: { abs($0 - index) <= spare }), !pinned(slice) {
            Color.clear.frame(height: (measured.height * measured.width / width).rounded())
        } else {
            segment(slice)
                .onGeometryChange(for: CGSize.self) { CGSize(width: $0.size.width.rounded(), height: $0.size.height) } action: {
                    sizes[index] = $0
                }
        }
    }
}
