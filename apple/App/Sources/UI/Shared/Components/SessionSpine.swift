import CueStore
import SwiftUI

/// 手机的会话条：贴屏幕左缘一条玻璃胶囊（边缘索引），每个会话一颗状态标，等你在上、推进中在下，两组之间一道缝；放不下时排前几个，末尾写 +N。
/// 按住上下滑（同通讯录右侧的 A–Z 索引）：胶囊长成一块面板列出全部会话，手指经过的那行高亮、给一下选择触感，松在哪行开哪行，松在行外不开、收起。
/// 轻点：面板留着，点行打开，放不下的滚着看；点外面、Esc 收起，面板里的空白不收。滑的时候不滚：只认摆出来的那几行。
/// 收起与展开是同一块玻璃、同一列状态标：标从胶囊里的位置滑到它那一行，名字在玻璃长宽时露出来，不先消失再淡入。
/// 被否决的：60 点宽的格子竖条（每格状态标加名字）——对话、舞台、拍板卡只能在剩下那块里居中，页头与输入框按整屏居中，整页偏右。
struct SessionSpine: View {
    let rows: SessionRailRows
    let open: (SessionState) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var pitch: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var tall: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var short: CGFloat = 32
    @State private var phase = DebugHooks.preset.railOpen ? Phase.pinned : .shut
    @State private var hovered: String?
    @State private var pressed: Date?

    private enum Phase { case shut, scrubbing, pinned }

    /// 胶囊的宽：状态标那一列加两边的 `Chrome.pad`（展开后行底离玻璃边同这一圈）。
    static let width: CGFloat = 34
    private static let mark: CGFloat = 12
    private static let column = width - 2 * Chrome.pad
    private static let panelWidth: CGFloat = 300
    private static let quietDot: CGFloat = 5
    /// 等你与推进中两组之间的缝。
    private static let split = Spacing.group
    /// 按下到松开不到这么久、挪不到这么远算轻点（面板留着）；否则是滑过，松在哪行开哪行。
    private static let tapTime: TimeInterval = 0.3
    private static let tapSlop: CGFloat = 10

    private var expanded: Bool { phase != .shut }

    var body: some View {
        GeometryReader { band in
            let full = Plan(rows, band: band.size, expanded: true, pitch: pitch, tall: tall, short: short)
            let plan = expanded ? full : Plan(rows, band: band.size, expanded: false, pitch: pitch, tall: tall, short: short)
            ZStack(alignment: .leading) {
                // 点外面收起：铺满整屏（连页头与输入框），面板盖在它上面，面板里的空白落在面板上、不收
                if phase == .pinned {
                    Color.clear.contentShape(.rect).ignoresSafeArea().onTapGesture { collapse() }
                        .readerHidden(true)
                }
                if plan.count > 0 { spine(plan, hits: full).padding(.leading, Spacing.tight) }
            }
            .frame(width: band.size.width, height: band.size.height, alignment: .leading)
        }
        .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion) ?? Motion.fade, value: expanded)
        .sensoryFeedback(.selection, trigger: hovered) { _, new in new != nil }
        .onChange(of: active) { _, active in if !active { collapse() } }
    }

    private func spine(_ plan: Plan, hits: Plan) -> some View {
        let shape = RoundedRectangle(cornerRadius: expanded ? Radius.sheet : Self.width / 2, style: .continuous)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.waiting) { row($0, plan) }
                if plan.splits { Color.clear.frame(height: Self.split) }
                ForEach(plan.advancing) { row($0, plan) }
                if plan.extra > 0 {
                    Text(verbatim: "+\(plan.extra)")
                        .font(Typography.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(palette.ink2)
                        .frame(width: Self.column, height: plan.rowHeight)
                        .readerHidden(true)
                }
            }
            .padding(Chrome.pad)
            .padding(.vertical, Spacing.tight)
        }
        .scrollDisabled(phase != .pinned)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: plan.width, height: plan.height, alignment: .topLeading)
        // 面板里的空白接住轻点、什么也不做：只有形状没有手势的地方，轻点会穿过去落到下面的对话上（实测）
        .background { if phase == .pinned { Color.clear.contentShape(.rect).onTapGesture {}.readerHidden(true) } }
        .clipShape(shape)
        .rowContainer(shape)
        .glass(in: shape)
        .contentShape(shape)
        .gesture(scrub(hits), isEnabled: phase != .pinned)
        .overlay {
            // 收着时读屏只认这一颗钮：标一颗颗都不读
            if !expanded {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(Text("会话"))
                    .accessibilityValue(Text(rows.waiting.count + rows.advancing.count, format: .number))
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

    private func row(_ item: SessionRailRows.Item, _ plan: Plan) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 0) {
                mark(item).frame(width: Self.column)
                if expanded {
                    words(item, twoLines: plan.twoLines)
                        .padding(.trailing, Spacing.item)
                        .frame(width: plan.width - Self.column - 2 * Chrome.pad, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .frame(height: plan.rowHeight, alignment: .leading)
        }
        .buttonStyle(RowStyle(selected: hovered == item.id))
        .allowsHitTesting(phase == .pinned)
        // 收着时这一行不进读屏，换成什么都没有：藏起（readerHidden）的话，标在动的那几行照样被列出来（模拟器无障碍树实测）
        .accessibilityRepresentation {
            if expanded {
                Button(item.name) { choose(item) }.accessibilityValue(Dotted(item.shown.label, line(item)).spoken)
            }
        }
        .transition(.opacity)
    }

    /// 空闲的会话 `StateDot` 不画东西：垫一颗淡墨小点占着位置，一列数下来几件就是几颗。
    private func mark(_ item: SessionRailRows.Item) -> some View {
        ZStack {
            if item.shown.isQuiet { Circle().fill(palette.track).frame(width: Self.quietDot, height: Self.quietDot) }
            StateDot(shown: item.shown, size: Self.mark)
        }
        .relaySpot(session: item.id, row: .rail)
    }

    /// 放得下两行时名字下面一行写它在做的那句；压矮了就接在名字后面，一行写完。
    private func words(_ item: SessionRailRows.Item, twoLines: Bool) -> some View {
        let name = Text(verbatim: item.name).font(Typography.secondary.weight(.medium))
            .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
        let said = line(item).map { Text(verbatim: $0).font(Typography.caption).foregroundStyle(palette.ink3) }
        return Group {
            if twoLines {
                VStack(alignment: .leading, spacing: Spacing.hair) { name; said }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) { name.layoutPriority(1); said }
            }
        }
        .lineLimit(1)
        .padding(.leading, Spacing.tight)
    }

    /// 它此刻在做什么，等你的写它问你的那句（同宽屏行的悬停提示）。
    private func line(_ item: SessionRailRows.Item) -> String? { item.waiting == nil ? item.doing : item.ask ?? item.doing }

    private func scrub(_ plan: Plan) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                // 第一下的坐标还是按胶囊量的：等面板排开、下一下再认行
                guard phase != .shut else {
                    pressed = .now
                    phase = .scrubbing
                    return
                }
                hovered = plan.item(at: drag.location)?.id
            }
            .onEnded { drag in
                let tap = Date.now.timeIntervalSince(pressed ?? .now) < Self.tapTime
                    && hypot(drag.translation.width, drag.translation.height) < Self.tapSlop
                if tap {
                    hovered = nil
                    phase = .pinned
                } else if let item = plan.item(at: drag.location) {
                    choose(item)
                } else {
                    collapse()
                }
            }
    }

    private func choose(_ item: SessionRailRows.Item) {
        open(item.session)
        collapse()
    }

    private func collapse() {
        hovered = nil
        phase = .shut
    }

    /// 一种摆法（收着或展开）下排哪些、一行多高、玻璃多大。只由可用的那一段高与会话数推出，滑过时按它反查手指在哪一行。
    private struct Plan {
        let waiting: [SessionRailRows.Item]
        let advancing: [SessionRailRows.Item]
        let extra: Int
        let rowHeight: CGFloat
        let twoLines: Bool
        let width: CGFloat
        let height: CGFloat

        var count: Int { waiting.count + advancing.count }
        var splits: Bool { !waiting.isEmpty && !advancing.isEmpty }
        private static var edge: CGFloat { Chrome.pad + Spacing.tight }

        /// 收着时一行就是一颗标的间距；展开时一行写名字与它在做的那句，放不下就压矮、只留名字，再放不下也排前面的、末尾 +N。
        init(_ rows: SessionRailRows, band: CGSize, expanded: Bool, pitch: CGFloat, tall: CGFloat, short: CGFloat) {
            let total = rows.waiting.count + rows.advancing.count
            // 展开的面板上下离页头与输入框各留一道缝，不贴着它们
            let room = band.height - 2 * Self.edge - (expanded ? 2 * Spacing.item : 0) - (rows.waiting.isEmpty || rows.advancing.isEmpty ? 0 : SessionSpine.split)
            let row = expanded ? min(tall, max(short, room / CGFloat(max(total, 1)))) : pitch
            let fits = Int(room / row)
            // 展开的全列出来，放不下的滚着看
            let shown = expanded || total <= fits ? total : max(0, fits - 1)
            waiting = Array(rows.waiting.prefix(shown))
            advancing = Array(rows.advancing.prefix(shown - waiting.count))
            extra = total - shown
            rowHeight = row
            twoLines = row >= tall - Spacing.tight
            width = expanded ? min(SessionSpine.panelWidth, band.width - Spacing.tight - Spacing.page) : SessionSpine.width
            let lines = CGFloat(shown + (extra > 0 ? 1 : 0))
            let content = 2 * Self.edge + lines * row + (!waiting.isEmpty && !advancing.isEmpty ? SessionSpine.split : 0)
            height = expanded ? min(content, band.height - 2 * Spacing.item) : content
        }

        /// 玻璃自己坐标里的一点落在哪一行；行外（上下两头的边、两组之间的缝、玻璃右边之外）为 nil。左边不限：手指压着屏幕边。
        func item(at point: CGPoint) -> SessionRailRows.Item? {
            guard point.x <= width, point.y < height else { return nil }
            var y = point.y - Self.edge
            for (index, group) in [waiting, advancing].enumerated() {
                if index == 1, splits { y -= SessionSpine.split }
                if y >= 0, y < CGFloat(group.count) * rowHeight { return group[Int(y / rowHeight)] }
                y -= CGFloat(group.count) * rowHeight
            }
            return nil
        }
    }
}
