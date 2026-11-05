#if os(macOS) && DEBUG
import AppKit

/// 宽屏跨阈值时主区与 Cue 的页面保住了没有（`InteractionBench+Wide` 的 `page`：ok、untested、broken）。
/// - 块视图与块里原来的每个滚动视图都还在（宽了多露出的不算）：页面没被重建，内容随路由与会话一起由 `Snapshot` 比；收起的 Cue 藏着时不比，露出来那一下再比；
/// - 每栏里每个能滚的滚动视图（看板的每一列、对话）都像用户那样滚到中段（`scrollToMiddle`），各记下可视区正中的那一条（看板卡、对话里的一条，按它们自己报的位置认，`benchSpot`）；
///   跨阈值后每一条都还在它那个滚动视图的可视区里，且没被滚回顶或底。栏宽变了内容会重新折行，离两端的距离跟着变，所以认那一条、不比距离。
///   读屏树认不了：没有辅助功能客户端连着时 SwiftUI 不在进程里建它。
struct WidePage {
    private let views: [WideSlot: [ObjectIdentifier]]
    private let readings: [Reading]
    /// 验不了的，按滚动视图算：每个能滚 `minimumTravel` 的滚动视图都要有一条读数，没有的记成"栏#序号:为什么"——序号是这一栏全部滚动视图（`scrolls`，含滚不到的）从左数的下标，从 0 起，同基线里 `scrolls`、`short` 的序号
    /// （没到中段、中段没认出一条）；一栏里一个能滚的都没有记成"栏:没有能滚的"。有一条就不算通过：同一栏里读到了一列，别的列漏验照样记在这里。
    let untested: [String]
    /// 基线时逐栏读到的：各滚动视图能滚多远、中段那个离两端多远、报了位置的条目有多少落在它的可视区里（读不到中段那一条时看缺在哪）。
    let baseline: [[String: Any]]

    private struct Reading {
        let column: WideSlot
        let scroll: ObjectIdentifier
        /// 可视区正中那一条与它离正中多远。
        let anchor: (id: AnyHashable, offset: CGFloat)
        let top: CGFloat
        let bottom: CGFloat
        /// 那一条报的框与可视区（托管视图坐标）：认不出时看是测量没对上还是它真的走了。
        let frame: CGRect?
        let visible: CGRect
    }

    /// 一栏的阅读位置：保住了、验不了（没东西可滚、没滚到中段、中段没认出一条），或没保住（对象换了、那一条不见了、被滚回一端）。
    /// 验不了不是通过：`perf-mac.sh` 在大库上把它判失败（大库的列与对话都长到能滚，就是为验这一条）。
    enum Verdict: String { case ok, untested, broken }

    /// 动作之后每一条读数为什么是那个判定，按先后只取第一条：
    /// - `scrollGone`：动作前那个滚动视图不在了（页被重建）；
    /// - `atEnd`：滚动视图被滚回顶或底；
    /// - `cardGone`：动作前正中那张卡不在可视区里了——不论是滚走了还是卡本身离开了这一列（列变空那一下推进中那张卡走了），都判没保住，
    ///   找不到不当成保住：要验的列里那张卡就不该被这一下挪走，挪走的卡只能在不验的列里（`InteractionBench+Board`）；
    /// - `kept`：还在眼前（藏起的 Cue 那一块不比，也记作它）。
    /// 正中那张卡在动作之前取（`init`，在 `step` 发出动作之前建这一份）。
    enum Reason: String { case kept, scrollGone, atEnd, cardGone }

    /// 滚到中段的那个滚动视图至少要能滚这么远：离两端各留出一截，滚回一端看得出来。
    private static let minimumTravel: CGFloat = 200

    /// 各块里每个能滚的滚动视图都滚到中段，像用户那样：先发开始实时滚动的通知（同 `ChatScrollBench` 的 direct），等两帧滚动区认出"用户在滚"再挪，
    /// 再等两帧、滚动区按这次滚动读过数才发结束的通知。挪与通知同在一拍里的话，读数到时还算没在滚，贴着最新的对话会被滚回最新处。
    static func scrollToMiddle(_ columns: [WideColumnView]) async {
        for scroll in columns.flatMap(scrollables) {
            guard let document = scroll.documentView else { continue }
            let clip = scroll.contentView
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            await NextFrame.wait()
            await NextFrame.wait()
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: (document.frame.height - clip.bounds.height) / 2))
            scroll.reflectScrolledClipView(clip)
            await NextFrame.wait()
            await NextFrame.wait()
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        // 滚到的那一截要几帧才排成真的（对话离屏的段是空白，`ChatSegments`），排好了才报位置：等到每栏都认得出一条，最多 `settleFrames` 帧
        for _ in 0..<settleFrames {
            if columns.allSatisfy({ column in scrollables(in: column).allSatisfy { !items(in: column, shownBy: $0).isEmpty } }) { return }
            await NextFrame.wait()
        }
    }

    /// 滚到中段后等条目报位置最多等几帧（约 2 秒）：到了还认不出，那一栏记作验不了。
    private static let settleFrames = 120

    init(_ columns: [WideColumnView]) {
        views = Dictionary(uniqueKeysWithValues: columns.map { ($0.slot, Self.objects(in: $0)) })
        baseline = columns.map { column in
            let scrolls = Self.scrollables(in: column)
            return [
                "column": "\(column.slot)", "scrolls": Self.scrolls(in: column).map { Self.round(($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height) },
                "spots": InteractionBench.rows.count, "shown": scrolls.map { Self.items(in: column, shownBy: $0).count },
                "ends": scrolls.compactMap(Self.ends).map { [Self.round($0.top), Self.round($0.bottom)] },
                // 滚不到 `minimumTravel` 的（列短、一屏放得下）：没有阅读位置可验，不算漏验，只列出来（能滚多远）
                "short": Self.scrolls(in: column).enumerated().filter { !Self.isScrollable($0.element) }.map { "#\($0.offset):\(Self.round(($0.element.documentView?.frame.height ?? 0) - $0.element.contentView.bounds.height))" },
            ]
        }
        // 每个能滚的滚动视图要么有一条读数，要么记进验不了（连同第几个、为什么）：不让同一栏里读到了的那一列盖住漏验的那一列
        var readings: [Reading] = [], untested: [String] = []
        for column in columns {
            let all = Self.scrolls(in: column)
            if !all.contains(where: Self.isScrollable) { untested.append("\(column.slot):没有能滚的") }
            for (index, scroll) in all.enumerated() where Self.isScrollable(scroll) {
                guard let (top, bottom) = Self.ends(of: scroll), top > 1, bottom > 1 else {
                    untested.append("\(column.slot)#\(index):没到中段")
                    continue
                }
                guard let anchor = Self.items(in: column, shownBy: scroll).min(by: { abs($0.offset) < abs($1.offset) }) else {
                    untested.append("\(column.slot)#\(index):中段没认出一条")
                    continue
                }
                readings.append(Reading(column: column.slot, scroll: ObjectIdentifier(scroll), anchor: anchor, top: top, bottom: bottom,
                                        frame: InteractionBench.rows[anchor.id], visible: Self.visible(scroll, in: column)))
            }
        }
        self.readings = readings
        self.untested = untested
    }

    /// 跨阈值之后的样子比起这份：对象换了或任一条读数没保住是 broken；都保住了但有滚动视图验不了是 untested，不算通过（整项按最差的那一条）。逐栏的明细给测量行：
    /// 离两端的距离、那一条离可视区正中多远、它报的框与可视区（跨阈值前后；看不见了为空）。
    /// 收起的 Cue 只是藏起、一直挂着（`MainWindow`）：藏着的那一块不比对象也不读位置（记作 kept），露出来的那一下再比。
    func compare(_ columns: [WideColumnView]) -> (verdict: Verdict, detail: [[String: Any]]) {
        let hidden = Set(columns.filter(\.isHidden).map(\.slot))
        // 原来的对象都还在就是没重建；宽了多露出一块（如对话下面放得下了的一排）不算
        let swapped = columns.filter { column in !hidden.contains(column.slot) && !Set(views[column.slot] ?? []).isSubset(of: Self.objects(in: column)) }
        let changed = !swapped.isEmpty
        let detail = readings.map { reading -> [String: Any] in
            let column = columns.first { $0.slot == reading.column }
            if hidden.contains(reading.column) { return ["column": "\(reading.column)", "verdict": Verdict.ok.rawValue, "reason": Reason.kept.rawValue] }
            let scroll = column.flatMap { Self.scrolls(in: $0).first { ObjectIdentifier($0) == reading.scroll } }
            let ends = scroll.flatMap(Self.ends)
            let shown = column.flatMap { column in scroll.flatMap { Self.items(in: column, shownBy: $0).first { $0.id == reading.anchor.id } } }
            let reason: Reason = scroll == nil ? .scrollGone : !(ends.map { $0.top > 1 && $0.bottom > 1 } ?? false) ? .atEnd : shown == nil ? .cardGone : .kept
            let verdict: Verdict = reason == .kept ? .ok : .broken
            let frame = InteractionBench.rows[reading.anchor.id]
            return [
                "column": "\(reading.column)", "anchor": "\(reading.anchor.id.base)", "verdict": verdict.rawValue, "reason": reason.rawValue,
                "ends": [[Self.round(reading.top), Self.round(reading.bottom)], ends.map { [Self.round($0.top), Self.round($0.bottom)] } ?? []],
                "anchorOffset": [Self.round(reading.anchor.offset), shown.map { Self.round($0.offset) as Any } ?? NSNull()],
                "anchorFrame": [Self.json(reading.frame), Self.json(frame)],
                "visible": [Self.json(reading.visible), Self.json(scroll.flatMap { scroll in column.map { Self.visible(scroll, in: $0) } })],
            ]
        }
        let verdicts = detail.compactMap { $0["verdict"] as? String }.compactMap(Verdict.init)
        if changed || verdicts.contains(.broken) {
            // 对象换了的那一块：列出它此刻的滚动视图（原来就有的 same、新出现或换了的 new），看是页被重建还是多出一块
            let objects = swapped.map { column -> [String: Any] in
                ["column": "\(column.slot)", "swapped": Self.scrolls(in: column).map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height)) \(views[column.slot]?.contains(ObjectIdentifier($0)) == true ? "same" : "new")" },
                 "before": views[column.slot]?.count ?? 0]
            }
            return (.broken, detail + objects)
        }
        return (untested.isEmpty ? .ok : .untested, detail)
    }

    private static func objects(in column: WideColumnView) -> [ObjectIdentifier] {
        [ObjectIdentifier(column)] + scrolls(in: column).map(ObjectIdentifier.init)
    }

    private static func json(_ rect: CGRect?) -> Any {
        rect.map { [round($0.minX), round($0.minY), round($0.width), round($0.height)] } ?? NSNull()
    }

    private static func round(_ value: CGFloat) -> Double { Double((value * 10).rounded() / 10) }

    /// 栏里看得见的滚动视图：没被藏起、不透明、真落在栏里（离开的页面常留在视图树里，只是藏起或透明），从左到右。
    private static func scrolls(in column: WideColumnView) -> [NSScrollView] {
        func visit(_ view: NSView) -> [NSScrollView] {
            guard !view.isHidden, view.alphaValue > 0, view.layer?.opacity != 0 else { return [] }
            let own = (view as? NSScrollView).flatMap {
                $0.documentView != nil && !column.convert($0.bounds, from: $0).intersection(column.bounds).isEmpty ? [$0] : nil
            } ?? []
            return own + view.subviews.flatMap(visit)
        }
        // 按在窗口里从左到右排（左沿一样的按视图树里的先后）：漏验、基线与列宽都用这一套序号
        return visit(column).enumerated()
            .sorted { (visible($0.element, in: column).minX, $0.offset) < (visible($1.element, in: column).minX, $1.offset) }
            .map(\.element)
    }

    /// 栏里竖着能滚 `minimumTravel` 以上的（看板的每一列、对话），从左到右。
    private static func scrollables(in column: WideColumnView) -> [NSScrollView] {
        scrolls(in: column).filter(isScrollable)
    }

    private static func isScrollable(_ scroll: NSScrollView) -> Bool {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height >= minimumTravel
    }

    /// 栏里各个滚动视图在窗口里的宽，按从左到右（列宽换档换没换宽，`InteractionBench+Board`）。
    static func widths(in column: WideColumnView) -> [Double] {
        scrolls(in: column).map { round(visible($0, in: column).width) }
    }

    /// 可视区离文档顶、底多远（文档视图翻没翻转都按看到的顶与底算）。
    private static func ends(of scroll: NSScrollView) -> (top: CGFloat, bottom: CGFloat)? {
        guard let document = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds, height = document.frame.height
        return document.isFlipped ? (visible.minY, height - visible.maxY) : (height - visible.maxY, visible.minY)
    }

    /// 报了位置的条目里落在这个滚动视图可视区里的（中心在里面）：它与离可视区正中多远。两样都按窗口算。
    /// 可视区在窗口里的框（左上为原点，同 `benchSpot` 报的位置）。
    private static func visible(_ scroll: NSScrollView, in column: WideColumnView) -> CGRect {
        guard let root = scroll.window?.contentView else { return .zero }
        let rect = scroll.contentView.convert(scroll.contentView.bounds, to: root)
        return root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func items(in column: WideColumnView, shownBy scroll: NSScrollView) -> [(id: AnyHashable, offset: CGFloat)] {
        let visible = visible(scroll, in: column)
        return InteractionBench.rows.compactMap { id, frame in
            visible.contains(CGPoint(x: frame.midX, y: frame.midY)) ? (id, frame.midY - visible.midY) : nil
        }
    }
}
#endif
