#if os(macOS) && DEBUG
import AppKit

/// 宽屏跨阈值时主区与 Cue 的页面保住了没有（`InteractionBench+Wide` 的 `page`：ok、untested、broken）。
/// - 块视图与块里原来的每个滚动视图都还在（宽了多露出的不算，窄了挤出块外的还算在；只认能滚的，`objects`）：页面没被重建，内容随路由与会话一起由 `Snapshot` 比；收起的 Cue 藏着时不比，露出来那一下再比；
/// - 每栏里每个能滚的滚动视图（看板的每一列、对话）都像用户那样滚到中段（`scrollToMiddle`），各记下可视区正中的那一条（看板卡、对话里的一条，按它们自己报的位置认，`benchSpot`）；
///   跨阈值后每一条都还在它那个滚动视图的可视区里，且没被滚回顶或底。栏宽变了内容会重新折行，离两端的距离跟着变，所以认那一条、不比距离。
///   读屏树认不了：没有辅助功能客户端连着时 SwiftUI 不在进程里建它。
struct WidePage {
    private let views: [ObjectIdentifier: [ObjectIdentifier]]
    private let readings: [Reading]
    let untested: [String]
    let baseline: [[String: Any]]

    private struct Reading {
        let column: ObjectIdentifier
        let name: String
        let scroll: ObjectIdentifier
        let anchor: (id: AnyHashable, offset: CGFloat)
        let top: CGFloat
        let bottom: CGFloat
        let frame: CGRect?
        let visible: CGRect
    }

    enum Verdict: String { case ok, untested, broken }

    enum Reason: String { case kept, scrollGone, atEnd, cardGone }

    private static let minimumTravel: CGFloat = 200

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
        func settled() -> Bool { columns.allSatisfy { column in scrollables(in: column).allSatisfy { !items(in: column, shownBy: $0).isEmpty } } }
        for _ in 0..<settleFrames {
            if settled() { return }
            await NextFrame.wait()
        }
        // 实测（大库、一个会话加 Cue）：一下跳到中段后到时限那一屏还没有一条报位置，再滚一下就报了（原因没查清：只有这里是一下跳过去的，人滚与跳去某一条都有后续的滚动读数）。
        // 往上挪半屏再认，到认得出一条或快到顶为止
        for _ in 0..<nudges {
            for column in columns {
                for scroll in scrollables(in: column) where items(in: column, shownBy: scroll).isEmpty {
                    guard let document = scroll.documentView, let (top, _) = ends(of: scroll) else { continue }
                    let clip = scroll.contentView, step = min(clip.bounds.height / 2, top - clip.bounds.height / 4)
                    guard step > 0 else { continue }
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + (document.isFlipped ? -step : step)))
                    scroll.reflectScrolledClipView(clip)
                }
            }
            for _ in 0..<20 { await NextFrame.wait() }
            if settled() { return }
        }
    }

    private static let nudges = 6

    private static let settleFrames = 120

    init(_ columns: [WideColumnView]) {
        views = Dictionary(uniqueKeysWithValues: columns.map { (ObjectIdentifier($0), Self.objects(in: $0, scrollable: true)) })
        baseline = columns.map { column in
            let scrolls = Self.scrollables(in: column)
            return [
                "column": "\(Self.name(column))", "scrolls": Self.scrolls(in: column).map { Self.round(($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height) },
                "spots": InteractionBench.rows.count, "shown": scrolls.map { Self.items(in: column, shownBy: $0).count },
                "ends": scrolls.compactMap(Self.ends).map { [Self.round($0.top), Self.round($0.bottom)] },
                "short": Self.scrolls(in: column).enumerated().filter { !Self.isScrollable($0.element) }.map { "#\($0.offset):\(Self.round(($0.element.documentView?.frame.height ?? 0) - $0.element.contentView.bounds.height))" },
            ]
        }
        var readings: [Reading] = [], untested: [String] = []
        for column in columns where column.slot != nil && !column.isHidden {
            let all = Self.scrolls(in: column)
            if !all.contains(where: Self.isScrollable) { untested.append("\(Self.name(column)):没有能滚的") }
            for (index, scroll) in all.enumerated() where Self.isScrollable(scroll) {
                guard let (top, bottom) = Self.ends(of: scroll), top > 1, bottom > 1 else {
                    untested.append("\(Self.name(column))#\(index):没到中段")
                    continue
                }
                guard let anchor = Self.items(in: column, shownBy: scroll).min(by: { abs($0.offset) < abs($1.offset) }) else {
                    untested.append("\(Self.name(column))#\(index):中段没认出一条")
                    continue
                }
                readings.append(Reading(column: ObjectIdentifier(column), name: Self.name(column), scroll: ObjectIdentifier(scroll), anchor: anchor, top: top, bottom: bottom,
                                        frame: InteractionBench.rows[anchor.id], visible: Self.visible(scroll, in: column)))
            }
        }
        if readings.isEmpty && untested.isEmpty { untested.append("这一排没有看得见的块") }
        self.readings = readings
        self.untested = untested
    }

    func compare(_ columns: [WideColumnView]) -> (verdict: Verdict, detail: [[String: Any]]) {
        let hidden = Set(columns.filter(\.isHidden).map(ObjectIdentifier.init))
        let swapped = columns.filter { column in !hidden.contains(ObjectIdentifier(column)) && !Set(views[ObjectIdentifier(column)] ?? []).isSubset(of: Self.objects(in: column)) }
        let changed = !swapped.isEmpty
        let detail = readings.map { reading -> [String: Any] in
            let column = columns.first { ObjectIdentifier($0) == reading.column }
            if hidden.contains(reading.column) { return ["column": reading.name, "verdict": Verdict.ok.rawValue, "reason": Reason.kept.rawValue] }
            let scroll = column.flatMap { Self.held(in: $0).first { ObjectIdentifier($0) == reading.scroll } }
            let ends = scroll.flatMap(Self.ends)
            let shown = column.flatMap { column in scroll.flatMap { Self.items(in: column, shownBy: $0).first { $0.id == reading.anchor.id } } }
            let reason: Reason = scroll == nil ? .scrollGone : !(ends.map { $0.top > 1 && $0.bottom > 1 } ?? false) ? .atEnd : shown == nil ? .cardGone : .kept
            let verdict: Verdict = reason == .kept ? .ok : .broken
            let frame = InteractionBench.rows[reading.anchor.id]
            return [
                "column": reading.name, "anchor": "\(reading.anchor.id.base)", "verdict": verdict.rawValue, "reason": reason.rawValue,
                "ends": [[Self.round(reading.top), Self.round(reading.bottom)], ends.map { [Self.round($0.top), Self.round($0.bottom)] } ?? []],
                "anchorOffset": [Self.round(reading.anchor.offset), shown.map { Self.round($0.offset) as Any } ?? NSNull()],
                "anchorFrame": [Self.json(reading.frame), Self.json(frame)],
                "visible": [Self.json(reading.visible), Self.json(scroll.flatMap { scroll in column.map { Self.visible(scroll, in: $0) } })],
            ]
        }
        let verdicts = detail.compactMap { $0["verdict"] as? String }.compactMap(Verdict.init)
        if changed || verdicts.contains(.broken) {
            let objects = swapped.map { column -> [String: Any] in
                ["column": "\(Self.name(column))", "swapped": Self.held(in: column).map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height)) \(views[ObjectIdentifier(column)]?.contains(ObjectIdentifier($0)) == true ? "same" : "new")" },
                 "before": views[ObjectIdentifier(column)]?.count ?? 0]
            }
            return (.broken, detail + objects)
        }
        return (untested.isEmpty ? .ok : .untested, detail)
    }

    private static func name(_ column: WideColumnView) -> String { column.slot.map { "\($0)" } ?? "off" }

    /// 跨阈值前只记块与能滚的（记着用户滚到哪的那几个）：对话里代码块的横滑条随惰性列表的行进出重建，不算页面换了。
    private static func objects(in column: WideColumnView, scrollable: Bool = false) -> [ObjectIdentifier] {
        [ObjectIdentifier(column)] + held(in: column).filter { !scrollable || isScrollable($0) }.map(ObjectIdentifier.init)
    }

    /// 认的是对象还在不在，不管看不看得见：窄了被挤出块外的列、藏起来的滚动区都还是原来那个。
    private static func held(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(held)
    }

    private static func json(_ rect: CGRect?) -> Any {
        rect.map { [round($0.minX), round($0.minY), round($0.width), round($0.height)] } ?? NSNull()
    }

    private static func round(_ value: CGFloat) -> Double { Double((value * 10).rounded() / 10) }

    private static func scrolls(in column: WideColumnView) -> [NSScrollView] {
        func visit(_ view: NSView) -> [NSScrollView] {
            guard !view.isHidden, view.alphaValue > 0, view.layer?.opacity != 0 else { return [] }
            let own = (view as? NSScrollView).flatMap {
                $0.documentView != nil && !column.convert($0.bounds, from: $0).intersection(column.bounds).isEmpty ? [$0] : nil
            } ?? []
            return own + view.subviews.flatMap(visit)
        }
        return visit(column).enumerated()
            .sorted { (visible($0.element, in: column).minX, $0.offset) < (visible($1.element, in: column).minX, $1.offset) }
            .map(\.element)
    }

    private static func scrollables(in column: WideColumnView) -> [NSScrollView] {
        scrolls(in: column).filter(isScrollable)
    }

    private static func isScrollable(_ scroll: NSScrollView) -> Bool {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height >= minimumTravel
    }

    private static func ends(of scroll: NSScrollView) -> (top: CGFloat, bottom: CGFloat)? {
        guard let document = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds, height = document.frame.height
        return document.isFlipped ? (visible.minY, height - visible.maxY) : (height - visible.maxY, visible.minY)
    }

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
