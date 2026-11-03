#if os(macOS) && DEBUG
import AppKit

/// 宽屏跨阈值时两栏的页面保住了没有（`InteractionBench+Wide` 的 `page`：ok、untested、broken）。
/// - 栏视图与栏里每个滚动视图还是原来那个对象：页面没被重建，内容随路由与会话一起由 `Snapshot` 比；
/// - 每栏滚得最远的那个滚动视图像用户那样滚到中段（`scrollToMiddle`），记下可视区正中的那一条（看板卡、对话里的一条，按它们自己报的位置认，`benchSpot`）；
///   跨阈值后这一条还在可视区里，且没被滚回顶或底。栏宽变了内容会重新折行，离两端的距离跟着变，所以认那一条、不比距离。
///   读屏树认不了：没有辅助功能客户端连着时 SwiftUI 不在进程里建它。
struct WidePage {
    private let views: [ObjectIdentifier]
    private let readings: [Reading]
    /// 栏里没有能滚 `minimumTravel` 的滚动视图（内容不到一屏多）：阅读位置在这一栏验不了，只比对象，测量行里列出来。
    let untested: [String]
    /// 基线时逐栏读到的：各滚动视图能滚多远、中段那个离两端多远、报了位置的条目有多少落在它的可视区里（读不到中段那一条时看缺在哪）。
    let baseline: [[String: Any]]

    private struct Reading {
        let column: Workspace.Column
        let scroll: ObjectIdentifier
        /// 可视区正中那一条与它离正中多远；没有条目落在可视区里时为 nil。
        let anchor: (id: AnyHashable, offset: CGFloat)?
        let top: CGFloat
        let bottom: CGFloat
        /// 那一条报的框与可视区（托管视图坐标）：认不出时看是测量没对上还是它真的走了。
        let frame: CGRect?
        let visible: CGRect
    }

    /// 一栏的阅读位置：保住了、验不了（没东西可滚、没滚到中段、中段没认出一条），或没保住（对象换了、那一条不见了、被滚回一端）。
    enum Verdict: String { case ok, untested, broken }

    /// 滚到中段的那个滚动视图至少要能滚这么远：离两端各留出一截，滚回一端看得出来。
    private static let minimumTravel: CGFloat = 200

    /// 两栏各把滚得最远的那个滚动视图滚到中段，像用户那样：先发开始实时滚动的通知（同 `ChatScrollBench` 的 direct），等两帧滚动区认出"用户在滚"再挪，
    /// 再等两帧、滚动区按这次滚动读过数才发结束的通知。挪与通知同在一拍里的话，读数到时还算没在滚，贴着最新的对话会被滚回最新处。
    static func scrollToMiddle(_ columns: [WideColumnView]) async {
        for column in columns {
            guard let scroll = primary(in: column), let document = scroll.documentView else { continue }
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
            if columns.allSatisfy({ column in primary(in: column).map { !items(in: column, shownBy: $0).isEmpty } ?? true }) { return }
            await NextFrame.wait()
        }
    }

    /// 滚到中段后等条目报位置最多等几帧（约 2 秒）：到了还认不出，那一栏记作验不了。
    private static let settleFrames = 120

    init(_ columns: [WideColumnView]) {
        views = columns.flatMap { [ObjectIdentifier($0)] + Self.scrolls(in: $0).map(ObjectIdentifier.init) }
        baseline = columns.map { column in
            let scroll = Self.primary(in: column)
            return [
                "column": "\(column.column)", "scrolls": Self.scrolls(in: column).map { Self.round(($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height) },
                "spots": InteractionBench.rows.count, "shown": scroll.map { Self.items(in: column, shownBy: $0).count } ?? 0,
                "ends": scroll.flatMap(Self.ends).map { [Self.round($0.top), Self.round($0.bottom)] } ?? [],
            ]
        }
        let readings: [Reading] = columns.compactMap { column in
            guard let scroll = Self.primary(in: column), let (top, bottom) = Self.ends(of: scroll) else { return nil }
            let anchor = Self.items(in: column, shownBy: scroll).min { abs($0.offset) < abs($1.offset) }
            return Reading(column: column.column, scroll: ObjectIdentifier(scroll), anchor: anchor, top: top, bottom: bottom,
                           frame: anchor.flatMap { InteractionBench.rows[$0.id] }, visible: Self.visible(scroll, in: column))
        }
        self.readings = readings
        // 验不了的栏：没有能滚的、没停在中段、中段没认出一条
        untested = columns.map(\.column).filter { column in
            guard let reading = readings.first(where: { $0.column == column }) else { return true }
            return reading.anchor == nil || reading.top <= 1 || reading.bottom <= 1
        }.map { "\($0)" }
    }

    /// 跨阈值之后的样子比起这份：对象换了或任一栏没保住是 broken；都保住了但有栏验不了是 untested，不算通过。逐栏的明细给测量行：
    /// 离两端的距离、那一条离可视区正中多远、它报的框与可视区（跨阈值前后；看不见了为空）。
    func compare(_ columns: [WideColumnView]) -> (verdict: Verdict, detail: [[String: Any]]) {
        let now = columns.flatMap { [ObjectIdentifier($0)] + Self.scrolls(in: $0).map(ObjectIdentifier.init) }
        let detail = readings.map { reading -> [String: Any] in
            let column = columns.first { $0.column == reading.column }
            let scroll = column.flatMap { Self.scrolls(in: $0).first { ObjectIdentifier($0) == reading.scroll } }
            let ends = scroll.flatMap(Self.ends)
            let shown = reading.anchor.flatMap { anchor in
                column.flatMap { column in scroll.flatMap { Self.items(in: column, shownBy: $0).first { $0.id == anchor.id } } }
            }
            let verdict: Verdict = untested.contains("\(reading.column)") ? .untested
                : shown != nil && (ends.map { $0.top > 1 && $0.bottom > 1 } ?? false) ? .ok : .broken
            let frame = reading.anchor.flatMap { InteractionBench.rows[$0.id] }
            return [
                "column": "\(reading.column)", "anchor": reading.anchor.map { "\($0.id.base)" } ?? "", "verdict": verdict.rawValue,
                "ends": [[Self.round(reading.top), Self.round(reading.bottom)], ends.map { [Self.round($0.top), Self.round($0.bottom)] } ?? []],
                "anchorOffset": [reading.anchor.map { Self.round($0.offset) as Any } ?? NSNull(), shown.map { Self.round($0.offset) as Any } ?? NSNull()],
                "anchorFrame": [Self.json(reading.frame), Self.json(frame)],
                "visible": [Self.json(reading.visible), Self.json(scroll.flatMap { scroll in column.map { Self.visible(scroll, in: $0) } })],
            ]
        }
        let verdicts = detail.compactMap { $0["verdict"] as? String }.compactMap(Verdict.init)
        if now != views || verdicts.contains(.broken) { return (.broken, detail) }
        return (untested.isEmpty ? .ok : .untested, detail)
    }

    private static func json(_ rect: CGRect?) -> Any {
        rect.map { [round($0.minX), round($0.minY), round($0.width), round($0.height)] } ?? NSNull()
    }

    private static func round(_ value: CGFloat) -> Double { Double((value * 10).rounded() / 10) }

    /// 栏里看得见的滚动视图：没被藏起、不透明、真落在栏里（离开的页面常留在视图树里，只是藏起或透明）。
    private static func scrolls(in column: WideColumnView) -> [NSScrollView] {
        func visit(_ view: NSView) -> [NSScrollView] {
            guard !view.isHidden, view.alphaValue > 0, view.layer?.opacity != 0 else { return [] }
            let own = (view as? NSScrollView).flatMap {
                $0.documentView != nil && !column.convert($0.bounds, from: $0).intersection(column.bounds).isEmpty ? [$0] : nil
            } ?? []
            return own + view.subviews.flatMap(visit)
        }
        return visit(column)
    }

    /// 栏里能滚得最远的那个（看板、对话），能滚不到 `minimumTravel` 的不算。
    private static func primary(in column: WideColumnView) -> NSScrollView? {
        scrolls(in: column)
            .map { ($0, ($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height) }
            .filter { $0.1 >= minimumTravel }
            .max { $0.1 < $1.1 }?.0
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
