#if os(macOS) && DEBUG
import AppKit
import CueStore

/// 宽屏自动阈值（`-CuePadBench interact` 的最后一段）：三种主区（看板、一个会话、并排两个会话）各在两道临界宽度上下 1 点来回改窗口宽（同人拖窗口边的那一下）：
/// 会话条自动收起（`WideMetrics.railThreshold`，256 ↔ 80）与 Cue 自动收成钮（`cueThreshold`）。每一下按 `measure` 的口径量回合、指令与掉帧，行里另记：
/// - `railPt`、`cue`：停下后会话条的宽与 Cue 露没露着，`railOK` 是这两样都对，`crossed` 是这一下真的跨过了阈值（会话条换了宽或 Cue 换了样；反向那一项是主区真的滑起来了）；
///   `stateOK`：偏好（会话条开合、Cue 开合、项目｜进展、当前项目）、主区去处与各份草稿都没被改；`page`：页面没被重建、每块停在中段读的那一项还在眼前（`WidePage`；ok、验不了的 untested、没保住的 broken，`pageUntested` 列出验不了的块），
///   `pages` 是逐栏的判定、锚点、跨阈值前后离顶与离底的距离、锚点离可视区正中多远、锚点的框与可视区（窗口坐标）。除了验不了，任一项不对 `perf-mac.sh` 判失败；
/// - `idleMainM`、`idleProcessM`：停下后再静置 500ms 主线程与整个进程的指令（百万）：布局反馈环会让窗口停着主线程也一直排版，它降不下来；进程那份含后台线程（同步、读库），不算排版；
/// - 反向那一项（`宽屏反向·…`）：收窄后 50ms（滑动刚起头）就拉回，滑动途中逐帧取主栏图层的呈现偏移（呈现层树里的左缘，即屏上的位置），`perFramePt` 是平均到每帧的最大位移（取样在主线程，主线程忙的那几帧取不到，两次取样之间按隔了几帧摊开；`gapFrames` 是隔得最多的一次）、`restPt` 是停下时离终点多远；`samples` 保留原始时刻与位置。
///   漏采的那几帧里有没有跳，这里证明不了：逐帧看屏上的样子录 `-CuePadWideReverse`（`DebugScene+Wide.swift`）。
/// 没被 `-CuePadInteractOnly` 选中的步骤照样改窗口宽、只是不量，选中的那一步总是从阈值另一侧跨过来。
extension InteractionBench {
    /// 跨阈值与侧栏开合是同一种变化（会话条或 Cue 换宽、主区按新宽排一次、叠一段滑动），用同一份预算。
    private static var wideBudget: (clickMs: Double, hitches: Int) { budgets["侧栏收起"]! }

    /// 三种主区：进展的看板，开着一个会话，并排两个会话；右边都是 Cue。
    struct WideCase {
        let name: String
        let sessions: Int
    }

    static let wideCases = [
        WideCase(name: "看板+Cue", sessions: 0),
        WideCase(name: "会话+Cue", sessions: 1),
        WideCase(name: "双会话+Cue", sessions: 2),
    ]

    /// 摆成这种组合：主区回进展的看板、Cue 开着，再按组合把 `sessions` 的前一两份开在主区（第二份并排）。
    /// 会话条在看板与别处都选宽版（`Workspace.railExpanded`）：看板上默认是图标条、没有可跨的会话条阈值，量的是在看板上选了宽版的那种。
    static func arrange(_ item: WideCase, in workspace: Workspace, sessions: [String]) {
        let ids = sessions.prefix(2).map { PiSessionState.recordID(sessionID: $0) }
        workspace.services.settings.navigationPane = .progress
        workspace.services.settings.cueOpen = true
        workspace.services.settings.railExpanded = true
        workspace.services.settings.boardRailExpanded = true
        workspace.selectWide(.progress)
        if item.sessions > 0 { workspace.openSession(ids[0], sessionID: sessions[0], in: .main) }
        if item.sessions > 1 { workspace.openSession(ids[1], sessionID: sessions[1], in: .beside) }
    }

    static func measureWide(_ workspace: Workspace, in window: NSWindow, sessions: [String], only: Set<String>?, foreground: Bool) async throws {
        let selected = wideCases.filter { item in only.map({ names(item).contains(where: $0.contains) }) ?? true }
        guard !selected.isEmpty else { return }
        guard sessions.count >= 2, let view = window.contentView else { throw DebugScene.Unmet("宽屏测量需要两份会话与已上屏的窗口") }
        let settings = workspace.services.settings
        let ids = sessions.prefix(2).map { PiSessionState.recordID(sessionID: $0) }
        for (index, id) in ids.enumerated() { settings.setReplyDraft(ComposerDraft(text: "宽屏草稿 \(index)"), for: id) }
        workspace.cue.draft = ComposerDraft(text: "宽屏 Cue 草稿")
        let height = window.contentLayoutRect.height
        // 不是这里要的改宽、主区去处与临界宽的变化都记下（连同改宽时的调用栈），附在下一行上：判不对时看是谁动了窗口或状态
        let watch = WideWatch(window: window, workspace: workspace)
        func resize(_ width: CGFloat) {
            watch.expected = width
            window.setContentSize(NSSize(width: width, height: height))
        }
        defer { watch.stop() }
        for item in selected {
            arrange(item, in: workspace, sessions: sessions)
            let threshold = WideMetrics.railThreshold(workspace), cueThreshold = WideMetrics.cueThreshold(workspace)
            resize(threshold)
            await Task.wait(for: .seconds(1))
            await WidePage.scrollToMiddle(wideColumns(in: view))
            let before = snapshot(workspace, ids: ids)
            let page = WidePage(wideColumns(in: view))
            func step(_ name: String, width: CGFloat, rail: CGFloat, cue: Bool = true, reverse: Bool = false) async {
                guard only?.contains(name) ?? true else {
                    // 不量也照样改宽：下一步才是从阈值另一侧跨过来（反向那一下停回原宽，不必做）
                    if !reverse { resize(width) }
                    return
                }
                let slide = reverse ? SlideSampler(columns(in: view)) : nil
                var railBefore: CGFloat = -1, cueBefore = false
                var timeline: [String] = []
                var pullBack: Task<Void, Never>?
                var start = CACurrentMediaTime()
                func mark(_ what: String) {
                    timeline.append("\(Int((CACurrentMediaTime() - start) * 1000))ms \(what) 窗宽\(Int(window.contentLayoutRect.width)) 主区x\(Int(columns(in: view).main?.windowFrame.minX ?? -1)) Cue露\(columns(in: view).cue?.isHidden == false)")
                }
                var row = await measure(name, in: view) {
                    railBefore = columns(in: view).main?.windowFrame.minX ?? -1
                    cueBefore = columns(in: view).cue?.isHidden == false
                    start = CACurrentMediaTime()
                    resize(width)
                    mark("改宽后")
                    slide?.start(in: view)
                    if reverse { pullBack = Task { await Task.wait(for: .milliseconds(50)); resize(threshold) } }
                }
                // 拉回那一下落地了才往下读、往下走：没等它的话它在负载高时晚到，会把后面某一步改过的窗口宽又改回临界宽（会话条变宽、Cue 露出），判那一步不对
                await pullBack?.value
                var moved = false
                if let slide {
                    moved = slide.minimum < railBefore - 1
                    row.merge(slide.stop()) { $1 }
                }
                mark("量完")
                let idle = (main: threadInstructionsMillions(), process: instructionsMillions())
                await Task.wait(for: .milliseconds(500))
                row["idleMainM"] = ((threadInstructionsMillions() - idle.main) * 10).rounded() / 10
                row["idleProcessM"] = ((instructionsMillions() - idle.process) * 10).rounded() / 10
                mark("静置后")
                // 读的那一刻的时间线（离动作发出的毫秒、窗口宽、主区左缘、Cue 露没露）：判不对时看是窗口被改回去了还是排版没跟上
                row["timeline"] = timeline
                row["widthAsked"] = Double(width)
                let shown = columns(in: view)
                let railPt = shown.main.map(\.windowFrame.minX) ?? -1
                let cueShown = shown.cue?.isHidden == false
                row["railPt"] = railPt
                row["cue"] = cueShown
                row["railOK"] = railPt == rail && cueShown == cue
                row["crossed"] = reverse ? moved : railBefore != railPt || cueBefore != cueShown
                row["stateOK"] = snapshot(workspace, ids: ids) == before
                let shownPage = page.compare(wideColumns(in: view))
                row["page"] = shownPage.verdict.rawValue
                row["pageUntested"] = page.untested
                row["pages"] = shownPage.detail
                row["pageBaseline"] = page.baseline
                row["budgetClickMs"] = wideBudget.clickMs
                row["budgetHitches"] = wideBudget.hitches
                row["foreground"] = foreground
                row["unexpected"] = watch.drain()
                print(jsonLine("INTERACT", row))
                fflush(stdout)
            }
            let narrow = Chrome.strip, wide = Chrome.rail
            for _ in 0..<2 {
                await step("宽屏收窄·\(item.name)", width: threshold - 1, rail: narrow)
                await step("宽屏展开·\(item.name)", width: threshold, rail: wide)
            }
            await step("宽屏反向·\(item.name)", width: threshold - 1, rail: wide, reverse: true)
            resize(cueThreshold)
            await Task.wait(for: .seconds(1))
            for _ in 0..<2 {
                await step("Cue 收钮·\(item.name)", width: cueThreshold - 1, rail: narrow, cue: false)
                await step("Cue 露出·\(item.name)", width: cueThreshold, rail: narrow)
            }
        }
    }

    private static func names(_ item: WideCase) -> [String] {
        ["宽屏收窄", "宽屏展开", "宽屏反向", "Cue 收钮", "Cue 露出"].map { "\($0)·\(item.name)" }
    }

    /// 改窗口宽不该动的东西：偏好、主区去处与草稿。
    private struct Snapshot: Equatable {
        let rail: Bool
        let boardRail: Bool
        let cue: Bool
        let pane: NavigationPane
        let project: UUID?
        let main: Route
        let beside: UUID?
        let drafts: [String]
    }

    private static func snapshot(_ workspace: Workspace, ids: [UUID]) -> Snapshot {
        let settings = workspace.services.settings
        return Snapshot(
            rail: settings.railExpanded, boardRail: settings.boardRailExpanded, cue: settings.cueOpen, pane: settings.navigationPane, project: settings.currentProject,
            main: workspace.mainRoute, beside: workspace.besideSession?.id,
            drafts: ids.map { settings.replyDraft(for: $0).text } + [workspace.cue.draft.text])
    }

    private static func columns(in view: NSView) -> (main: WideColumnView?, cue: WideColumnView?) {
        let all = wideColumns(in: view)
        return (all.first { $0.slot == .main }, all.first { $0.slot == .cue })
    }

    static func wideColumns(in view: NSView) -> [WideColumnView] {
        if let column = view as? WideColumnView { return [column] }
        return view.subviews.flatMap(wideColumns)
    }
}

/// 滑动途中每帧取主栏在屏上的左缘：按呈现层树换算（叠加的几段平移在渲染端相加，呈现层上是总和；模型层跨阈值那一下就到了终点，读它会把提交前后的错位当成跳动）。
private final class SlideSampler: NSObject {
    private let column: WideColumnView?
    private var link: CADisplayLink?
    private var offsets: [(time: CFTimeInterval, x: CGFloat)] = []
    private var refresh: CFTimeInterval = 1.0 / 60
    /// 取到的最左位置（没取到时是无穷大）。
    var minimum: CGFloat { offsets.map(\.x).min() ?? .infinity }

    init(_ columns: (main: WideColumnView?, cue: WideColumnView?)) { column = columns.main }

    func start(in view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        refresh = link.duration > 0 ? link.duration : refresh
        guard let layer = column?.layer?.presentation(), let root = column?.window?.contentView?.superview?.layer?.presentation() else { return }
        offsets.append((link.timestamp, layer.convert(layer.bounds, to: root).minX))
    }

    func stop() -> [String: Any] {
        link?.invalidate()
        let rest = (offsets.last?.x ?? 0) - (column?.windowFrame.minX ?? 0)
        let steps = zip(offsets.dropFirst(), offsets).map { next, last in
            (move: abs(next.x - last.x), frames: max(1, ((next.time - last.time) / refresh).rounded()))
        }
        let jump = steps.map { $0.move / $0.frames }.max() ?? 0
        return [
            "perFramePt": (jump * 10).rounded() / 10, "restPt": (rest * 10).rounded() / 10,
            "gapFrames": steps.map(\.frames).max() ?? 0,
            "samples": offsets.map { ["ms": (($0.time - (offsets.first?.time ?? 0)) * 10_000).rounded() / 10, "x": ($0.x * 10).rounded() / 10] },
        ]
    }
}

private extension NSView {
    var windowFrame: CGRect { convert(bounds, to: nil) }
}

/// 宽屏阈值测量期间盯着两样（`measureWide`）：窗口被改成不是测量要的宽（记下当时的调用栈），主区去处、两道临界宽与两个开合偏好的每一次变化。
/// 各带离开始多少毫秒，攒到下一行测量里（`drain`）。
@MainActor final class WideWatch {
    var expected: CGFloat
    private var events: [String] = []
    private let start = CACurrentMediaTime()
    private var observer: (any NSObjectProtocol)?
    private var task: Task<Void, Never>?

    init(window: NSWindow, workspace: Workspace) {
        expected = window.contentLayoutRect.width
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, window.contentLayoutRect.width != self.expected else { return }
                self.note("窗宽变成 \(Int(window.contentLayoutRect.width))（要的是 \(Int(self.expected))）：" + Thread.callStackSymbols.prefix(18).joined(separator: " | "))
            }
        }
        task = Task { [weak self] in
            for await state in Observations({
                "\(workspace.mainRoute) 收会话条\(Int(WideMetrics.railThreshold(workspace))) 收Cue\(Int(WideMetrics.cueThreshold(workspace))) 会话条\(workspace.sidebarOpen) Cue\(workspace.services.settings.cueOpen) 浮\(workspace.cueFloats)"
            }) { self?.note(state) }
        }
    }

    private func note(_ what: String) { events.append("\(Int((CACurrentMediaTime() - start) * 1000))ms \(what)") }

    func drain() -> [String] {
        defer { events = [] }
        return events
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        task?.cancel()
    }
}
#endif
