import SwiftUI

/// 边缘索引：贴屏幕一边的一列记号，一项一颗，展开成一块面板列出全部。四个阶段（`Phase`）与它们之间的每一条路：
/// - 收着 → 按住滑（触屏按住记号那一列，同通讯录右侧的 A–Z 索引）：手指经过的那行高亮、给一下选择触感。松在哪行选哪行、收起；松在行外不选、收起；
///   按下到松开又短又没挪（轻点）→ 钉住。
/// - 收着 → 钉住：读屏激活收着时的那一颗钮（调试参数 `-CuePadIndexOpen` 一出现就是这样）。钉住时点行选、放不下的滚着看；点外面、Esc 收起，面板里的空白不收，
///   指针进出不管它。
/// - 收着 → 悬停（指针，Mac 与 iPad 的触控板）：指针移到记号上就展开，移出面板收起，点行选、收起。
///   Mac 上没有按住滑：指针总是先到记号上、先展开成悬停，按下落在行上（窗口刚到前台时指针已经停在那里也一样先报悬停，实测）。
/// - 任何时候页面不在前台、选了一行、Esc → 收着。
/// 收起与展开是同一块玻璃、同一列记号：记号从收着的位置滑到它那一行，字在玻璃长宽时露出来，不先消失再淡入。
/// 面板放不下全部时，滑的时候列表跟着手指等比滚：手指在面板上沿是第一行、下沿是最后一行，手指下面一直是它指着的那一行；放得下时不滚，只认摆出来的那几行。
/// 会话条（`SessionSpine`）与对话目录（`ChatIndex`）只给各项、此刻在哪一项与每行怎么画。
struct EdgeIndex<Item: Identifiable, Mark: View, Words: View, Overflow: View>: View {
    private let groups: [[Item]]
    private let edge: HorizontalEdge
    private let metrics: EdgeIndexMetrics
    private let shut: EdgeIndexShut
    private let current: Item.ID?
    private let label: LocalizedStringResource
    private let spoken: (Item) -> (name: String, value: String)
    private let choose: (Item) -> Void
    private let expandedChanged: (Bool) -> Void
    private let mark: (Item, EdgeIndexCell) -> Mark
    private let words: (Item, EdgeIndexCell) -> Words
    private let overflow: ([Item.ID]) -> Overflow
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase
    @State private var under: Item.ID?
    @State private var pressed: Date?
    @State private var position = ScrollPosition()
    @State private var scrubbed: CGFloat = 0

    private enum Phase { case shut, scrubbing, pinned, hovering }

    private static var split: CGFloat { Spacing.group }
    /// 按下到松开不到这么久、挪不到这么远算轻点（面板留着）；否则是滑过，松在哪行选哪行。
    private static var tapTime: TimeInterval { 0.3 }
    private static var tapSlop: CGFloat { 10 }

    init(
        groups: [[Item]], edge: HorizontalEdge, metrics: EdgeIndexMetrics, shut: EdgeIndexShut, current: Item.ID? = nil,
        label: LocalizedStringResource, spoken: @escaping (Item) -> (name: String, value: String), choose: @escaping (Item) -> Void,
        expandedChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder mark: @escaping (Item, EdgeIndexCell) -> Mark, @ViewBuilder words: @escaping (Item, EdgeIndexCell) -> Words,
        @ViewBuilder overflow: @escaping ([Item.ID]) -> Overflow
    ) {
        self.groups = groups
        self.edge = edge
        self.metrics = metrics
        self.shut = shut
        self.current = current
        self.label = label
        self.spoken = spoken
        self.choose = choose
        self.expandedChanged = expandedChanged
        self.mark = mark
        self.words = words
        self.overflow = overflow
        _phase = State(initialValue: DebugHooks.preset.indexOpen == edge ? .pinned : .shut)
    }

    private var expanded: Bool { phase != .shut }
    private var browsing: Bool { phase == .pinned || phase == .hovering }

    var body: some View {
        GeometryReader { band in
            let full = plan(band.size, expanded: true)
            let shown = expanded ? full : plan(band.size, expanded: false)
            ZStack(alignment: edge == .leading ? .leading : .trailing) {
                // 点外面收起：铺满整屏（连页头与输入框），面板盖在它上面，面板里的空白落在面板上、不收
                if phase == .pinned {
                    Color.clear.contentShape(.rect).ignoresSafeArea().onTapGesture { collapse() }
                        .readerHidden(true)
                }
                if shown.count > 0 {
                    index(shown, full: full).padding(edge == .leading ? .leading : .trailing, Spacing.tight)
                }
            }
            .frame(width: band.size.width, height: band.size.height, alignment: edge == .leading ? .leading : .trailing)
            .onChange(of: current == nil) { if browsing { position.scrollTo(y: full.offset(anchor: full.anchor(current))) } }
        }
        .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion) ?? Motion.fade, value: expanded)
        .sensoryFeedback(.selection, trigger: under) { _, new in new != nil }
        .onChange(of: active) { _, active in if !active { collapse() } }
        .onChange(of: expanded, initial: true) { _, expanded in expandedChanged(expanded) }
    }

    private func plan(_ band: CGSize, expanded: Bool) -> Plan {
        Plan(groups, current: current, shut: shut, band: band, expanded: expanded, metrics: metrics)
    }

    private func index(_ plan: Plan, full: Plan) -> some View {
        let shape = RoundedRectangle(cornerRadius: expanded ? Radius.sheet : metrics.width / 2, style: .continuous)
        return ScrollView {
            VStack(alignment: edge == .leading ? .leading : .trailing, spacing: 0) {
                ForEach(plan.groups.indices, id: \.self) { index in
                    if plan.splits(before: index) { Color.clear.frame(height: Self.split) }
                    ForEach(plan.groups[index]) { row($0, plan) }
                }
                if !plan.hidden.isEmpty {
                    Text(verbatim: "+\(plan.hidden.count)")
                        .font(Typography.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(palette.ink2)
                        .frame(width: metrics.column, height: plan.rowHeight)
                        .background { overflow(plan.hidden) }
                        .readerHidden(true)
                }
            }
            .padding(Chrome.pad)
            .padding(.vertical, Spacing.tight)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(UnitPoint(x: 0, y: phase == .scrubbing ? scrubbed : full.anchor(current)), for: .sizeChanges)
        .defaultScrollAnchor(UnitPoint(x: 0, y: full.anchor(current)), for: .initialOffset)
        .scrollDisabled(!browsing)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: plan.width, height: plan.height, alignment: edge == .leading ? .topLeading : .topTrailing)
        // 面板里的空白接住轻点、什么也不做：只有形状没有手势的地方，轻点会穿过去落到下面的内容上（实测）
        .background { if browsing { Color.clear.contentShape(.rect).onTapGesture {}.readerHidden(true) } }
        .clipShape(shape)
        .rowContainer(shape)
        .glass(in: shape, ink: .veil, shown: shut == .capsule || expanded)
        .contentShape(shape)
        .onHover(perform: hover)
        #if os(iOS)
        .gesture(scrub(full, from: plan), isEnabled: !browsing)
        #else
        .presetHover(Binding { phase == .hovering } set: { hover($0) })
        #endif
        .overlay {
            // 收着时读屏只认这一颗钮：记号一颗颗都不读
            if !expanded {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(Text(label))
                    .accessibilityValue(Text(full.count, format: .number))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { phase = .pinned }
            }
        }
        .background {
            // 外接键盘的 Esc；读屏的退出手势在下面
            if expanded { Button("收起", action: collapse).keyboardShortcut(.cancelAction).hidden() }
        }
        .accessibilityAction(.escape) { collapse() }
    }

    private func row(_ item: Item, _ plan: Plan) -> some View {
        let cell = EdgeIndexCell(expanded: expanded, twoLines: plan.twoLines, current: item.id == plan.marked)
        let far: Edge.Set = edge == .leading ? .trailing : .leading
        let said = expanded ? words(item, cell)
            .padding(far, Spacing.item)
            .frame(width: plan.width - metrics.column - 2 * Chrome.pad, alignment: .leading)
            .transition(.opacity) : nil
        return Button { pick(item) } label: {
            HStack(spacing: 0) {
                if edge == .trailing { said }
                mark(item, cell).frame(width: metrics.column)
                if edge == .leading { said }
            }
            .frame(height: plan.rowHeight, alignment: edge == .leading ? .leading : .trailing)
        }
        .buttonStyle(RowStyle(selected: under.map { $0 == item.id } ?? (expanded && cell.current), cell: true))
        .allowsHitTesting(browsing)
        // 收着时这一行不进读屏，换成什么都没有：藏起（readerHidden）的话，记号在动的那几行照样被列出来（模拟器无障碍树实测）
        .accessibilityRepresentation {
            if expanded {
                let spoken = spoken(item)
                Button(spoken.name) { pick(item) }
                    .accessibilityValue(spoken.value)
                    .accessibilityAddTraits(cell.current ? .isSelected : [])
            }
        }
        .transition(.opacity)
    }

    #if os(iOS)
    private func scrub(_ plan: Plan, from shut: Plan) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                // 第一下的坐标还是按收着的那一列量的：等面板排开、下一下再认行
                guard phase != .shut else {
                    pressed = .now
                    scrubbed = shut.fraction(finger: drag.location.y)
                    phase = .scrubbing
                    return
                }
                let offset = plan.offset(anchor: plan.fraction(finger: drag.location.y))
                position.scrollTo(y: offset)
                under = plan.item(at: drag.location, offset: offset, edge: edge)?.id
            }
            .onEnded { drag in
                let tap = Date.now.timeIntervalSince(pressed ?? .now) < Self.tapTime
                    && hypot(drag.translation.width, drag.translation.height) < Self.tapSlop
                if tap {
                    under = nil
                    phase = .pinned
                } else if let item = plan.item(at: drag.location, offset: plan.offset(anchor: plan.fraction(finger: drag.location.y)), edge: edge) {
                    pick(item)
                } else {
                    collapse()
                }
            }
    }
    #endif

    private func hover(_ inside: Bool) {
        if inside, phase == .shut {
            phase = .hovering
        } else if !inside, phase == .hovering {
            collapse()
        }
    }

    private func pick(_ item: Item) {
        choose(item)
        collapse()
    }

    private func collapse() {
        under = nil
        phase = .shut
    }

    /// 一种摆法（收着或展开）下排哪些、一行多高、玻璃多大。只由可用的那一段高与项数推出，滑过时按它反查手指在哪一行。
    private struct Plan {
        let groups: [[Item]]
        /// 收着放不下、收进 +N 的。
        let hidden: [Item.ID]
        let marked: Item.ID?
        let count: Int
        let rowHeight: CGFloat
        let twoLines: Bool
        let width: CGFloat
        let height: CGFloat
        let content: CGFloat
        private static var edge: CGFloat { Chrome.pad + Spacing.tight }

        /// 收着时一行就是一颗记号的间距；展开时放不下就压矮，再放不下全列出来滚着看。
        init(_ all: [[Item]], current: Item.ID?, shut: EdgeIndexShut, band: CGSize, expanded: Bool, metrics: EdgeIndexMetrics) {
            let filled = all.filter { !$0.isEmpty }
            let items = filled.flatMap(\.self)
            let total = items.count
            let splits = CGFloat(max(0, filled.count - 1)) * EdgeIndex.split
            // 展开的面板上下离页头与输入框各留一道缝，不贴着它们
            let room = band.height - 2 * Self.edge - (expanded ? 2 * Spacing.item : 0) - splits
            let row = expanded ? min(metrics.tall, max(metrics.short, room / CGFloat(max(total, 1)))) : metrics.pitch
            let fits = max(0, Int(room / row))
            let at = current.flatMap { id in items.firstIndex { $0.id == id } }
            var kept = Set(items.indices)
            switch shut {
            case .capsule where !expanded && total > fits:
                kept = Set(0..<max(0, fits - 1))
            case .marks(let limit) where !expanded && total > min(fits, limit):
                let shown = min(fits, limit)
                kept = shown > 1 ? Set((0..<shown).map { (total - 1) * $0 / (shown - 1) }) : shown == 1 ? [total - 1] : []
            case .capsule, .marks:
                break
            }
            var start = 0
            let groups = all.map { group in
                defer { start += group.count }
                return group.indices.compactMap { kept.contains(start + $0) ? group[$0] : nil }
            }
            self.groups = groups
            if shut == .capsule {
                hidden = items.indices.filter { !kept.contains($0) }.map { items[$0].id }
                marked = at.flatMap { kept.contains($0) ? items[$0].id : nil }
            } else {
                hidden = []
                marked = at.flatMap { at in kept.filter { $0 <= at }.max() ?? kept.min() }.map { items[$0].id }
            }
            count = total
            rowHeight = row
            twoLines = row >= metrics.tall - Spacing.tight
            width = expanded ? min(metrics.panel, band.width - Spacing.tight - Spacing.page) : metrics.width
            let lines = CGFloat(kept.count + (hidden.isEmpty ? 0 : 1))
            let shownSplits = CGFloat(groups.indices.count { index in Self.splits(groups, before: index) })
            content = 2 * Self.edge + lines * row + shownSplits * EdgeIndex.split
            height = expanded ? min(content, band.height - 2 * Spacing.item) : content
        }

        func splits(before index: Int) -> Bool { Self.splits(groups, before: index) }

        private static func splits(_ groups: [[Item]], before index: Int) -> Bool {
            !groups[index].isEmpty && groups[..<index].contains { !$0.isEmpty }
        }

        func fraction(finger y: CGFloat) -> CGFloat {
            height > 2 * Self.edge ? min(max((y - Self.edge) / (height - 2 * Self.edge), 0), 1) : 0
        }

        func offset(anchor: CGFloat) -> CGFloat { max(0, content - height) * anchor }

        func anchor(_ id: Item.ID?) -> CGFloat {
            var top = Self.edge
            for (index, group) in groups.enumerated() {
                if splits(before: index) { top += EdgeIndex.split }
                if let row = group.firstIndex(where: { $0.id == id }) {
                    return content > height ? min(max((top + (CGFloat(row) + 0.5) * rowHeight - height / 2) / (content - height), 0), 1) : 0
                }
                top += CGFloat(group.count) * rowHeight
            }
            return 0
        }

        /// 玻璃自己坐标里的一点（列表滚了 `offset`）落在哪一行；行外（上下两头的边、两组之间的缝、玻璃朝里那边之外）为 nil。贴着的那一边不限：手指压着屏幕边。
        func item(at point: CGPoint, offset: CGFloat, edge: HorizontalEdge) -> Item? {
            guard edge == .leading ? point.x <= width : point.x >= 0, point.y < height else { return nil }
            var y = point.y + offset - Self.edge
            for (index, group) in groups.enumerated() {
                if splits(before: index) { y -= EdgeIndex.split }
                if y >= 0, y < CGFloat(group.count) * rowHeight { return group[Int(y / rowHeight)] }
                y -= CGFloat(group.count) * rowHeight
            }
            return nil
        }
    }
}

struct EdgeIndexMetrics {
    /// 收着那一列的宽：记号那一列加两边的 `Chrome.pad`（展开后行底离玻璃边同这一圈）。
    let width: CGFloat
    let pitch: CGFloat
    let tall: CGFloat
    let short: CGFloat
    let panel: CGFloat

    var column: CGFloat { width - 2 * Chrome.pad }
}

/// 收着时长什么样。
enum EdgeIndexShut: Equatable {
    /// 一条玻璃胶囊（会话条）：从头排放得下的几项，其余收进末尾的 +N。
    case capsule
    /// 不垫玻璃的一列淡记号（对话目录）：最多这么多颗，从头到尾等距抽；此刻那一项落在抽到的、它往前最近的那一颗上。
    case marks(Int)
}

struct EdgeIndexCell {
    let expanded: Bool
    let twoLines: Bool
    let current: Bool
}
