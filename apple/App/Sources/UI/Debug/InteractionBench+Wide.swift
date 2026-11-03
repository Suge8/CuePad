#if os(macOS) && DEBUG
import AppKit
import CueStore

/// 宽屏自动阈值（`-CuePadBench interact` 的最后一段）：四种两栏组合各在会话条自动收窄的临界宽度上下 1 点来回改窗口宽（同人拖窗口边的那一下），
/// 每一下按 `measure` 的口径量回合、指令与掉帧，行里另记：
/// - `railPt`、`sidePt`：停下后会话条与右栏的宽，`railOK` 是会话条宽对，`crossed` 是这一下真的跨过了阈值（会话条换了宽；反向那一项是主栏真的滑起来了）；
///   `stateOK`：偏好（会话条开合、项目｜进展、当前项目、看板｜会话）、两栏去处与各份草稿都没被改；`pageOK`：两栏的栏视图与栏里每个滚动视图还是原来那个对象
///   （页面没被重建），且各自离顶或离底的距离没变（看板停在顶、对话停在最新处；栏宽变了对话会重新折行，离顶的距离跟着变）。任一项不对 `perf-mac.sh` 判失败；
/// - `idleMainM`、`idleProcessM`：停下后再静置 500ms 主线程与整个进程的指令（百万）：布局反馈环会让窗口停着主线程也一直排版，它降不下来；进程那份含后台线程（同步、读库），不算排版；
/// - 反向那一项（`宽屏反向·…`）：收窄后 50ms（滑动刚起头）就拉回，滑动途中逐帧取主栏图层的呈现偏移（呈现层树里的左缘，即屏上的位置），`perFramePt` 是平均到每帧的最大位移（取样在主线程，主线程忙的那几帧取不到，两次取样之间按隔了几帧摊开；`gapFrames` 是隔得最多的一次）、`restPt` 是停下时离终点多远；`samples` 保留原始时刻与位置。
///   漏采的那几帧里有没有跳，这里证明不了：逐帧看屏上的样子录 `-CuePadWideReverse`（`DebugScene+Wide.swift`）。
/// 没被 `-CuePadInteractOnly` 选中的步骤照样改窗口宽、只是不量，选中的那一步总是从阈值另一侧跨过来。临界宽度取 `WideMetrics.threshold`。
extension InteractionBench {
    /// 跨阈值与侧栏开合是同一种变化（会话条换宽、两栏按新宽排一次、叠一段滑动），用同一份预算。
    private static var wideBudget: (clickMs: Double, hitches: Int) { budgets["侧栏收起"]! }

    /// 四种两栏组合：主栏是看板还是一份会话，右栏是 Cue 还是另一份会话。
    struct WideCase {
        let name: String
        let main: Bool
        let side: Bool
    }

    static let wideCases = [
        WideCase(name: "看板+Cue", main: false, side: false),
        WideCase(name: "看板+会话", main: false, side: true),
        WideCase(name: "双会话", main: true, side: true),
        WideCase(name: "左会话+Cue", main: true, side: false),
    ]

    /// 摆成这种组合：主栏回进展的看板、右栏回 Cue，再按组合把 `sessions` 的前两份放进主栏、右栏。
    static func arrange(_ item: WideCase, in workspace: Workspace, sessions: [String]) {
        let ids = sessions.prefix(2).map { PiSessionState.recordID(sessionID: $0) }
        workspace.services.settings.navigationPane = .progress
        workspace.progressPane = .board
        workspace.selectWide(.progress)
        workspace.selectWide(.cue)
        if item.main { workspace.openSession(ids[0], sessionID: sessions[0], in: .main) }
        if item.side { workspace.openSession(ids[1], sessionID: sessions[1], in: .side) }
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
        for item in selected {
            arrange(item, in: workspace, sessions: sessions)
            let threshold = WideMetrics.threshold(workspace)
            window.setContentSize(NSSize(width: threshold, height: height))
            await Task.wait(for: .seconds(1))
            let before = snapshot(workspace, ids: ids)
            let page = pages(in: view)
            func step(_ name: String, width: CGFloat, rail: CGFloat, reverse: Bool = false) async {
                guard only?.contains(name) ?? true else {
                    // 不量也照样改宽：下一步才是从阈值另一侧跨过来（反向那一下停回原宽，不必做）
                    if !reverse { window.setContentSize(NSSize(width: width, height: height)) }
                    return
                }
                let slide = reverse ? SlideSampler(columns(in: view)) : nil
                var railBefore: CGFloat = -1
                var row = await measure(name, in: view) {
                    railBefore = columns(in: view).main?.windowFrame.minX ?? -1
                    window.setContentSize(NSSize(width: width, height: height))
                    slide?.start(in: view)
                    if reverse { Task { await Task.wait(for: .milliseconds(50)); window.setContentSize(NSSize(width: threshold, height: height)) } }
                }
                var moved = false
                if let slide {
                    moved = slide.minimum < railBefore - 1
                    row.merge(slide.stop()) { $1 }
                }
                let idle = (main: threadInstructionsMillions(), process: instructionsMillions())
                await Task.wait(for: .milliseconds(500))
                row["idleMainM"] = ((threadInstructionsMillions() - idle.main) * 10).rounded() / 10
                row["idleProcessM"] = ((instructionsMillions() - idle.process) * 10).rounded() / 10
                let shown = columns(in: view)
                let railPt = shown.main.map(\.windowFrame.minX) ?? -1
                row["railPt"] = railPt
                row["sidePt"] = shown.side?.frame.width ?? -1
                row["railOK"] = railPt == rail
                row["crossed"] = reverse ? moved : railBefore != railPt
                row["stateOK"] = snapshot(workspace, ids: ids) == before
                let shownPage = pages(in: view)
                row["pageOK"] = kept(page, shownPage)
                row["pageScrolls"] = shownPage.count
                row["budgetClickMs"] = wideBudget.clickMs
                row["budgetHitches"] = wideBudget.hitches
                row["foreground"] = foreground
                print(jsonLine("INTERACT", row))
                fflush(stdout)
            }
            let narrow = SessionRail.Form.narrow.width, wide = SessionRail.Form.wide.width
            for _ in 0..<2 {
                await step("宽屏收窄·\(item.name)", width: threshold - 1, rail: narrow)
                await step("宽屏展开·\(item.name)", width: threshold, rail: wide)
            }
            await step("宽屏反向·\(item.name)", width: threshold - 1, rail: wide, reverse: true)
        }
    }

    private static func names(_ item: WideCase) -> [String] { ["收窄", "展开", "反向"].map { "宽屏\($0)·\(item.name)" } }

    /// 改窗口宽不该动的东西：偏好、两栏去处与草稿。
    private struct Snapshot: Equatable {
        let rail: Bool
        let pane: NavigationPane
        let project: UUID?
        let progress: ProgressPane
        let main: Route
        let side: UUID?
        let drafts: [String]
    }

    private static func snapshot(_ workspace: Workspace, ids: [UUID]) -> Snapshot {
        let settings = workspace.services.settings
        return Snapshot(
            rail: settings.railExpanded, pane: settings.navigationPane, project: settings.currentProject, progress: workspace.progressPane,
            main: workspace.mainRoute, side: workspace.sideSession?.id,
            drafts: ids.map { settings.replyDraft(for: $0).text } + [workspace.cue.draft.text])
    }

    /// 栏视图与滚动视图（对象标识）和滚动视图离文档两端的距离；栏视图的距离记 0。文档视图翻没翻转都行：判的时候两端任一端没变就算没变。
    private struct Scroll {
        let id: ObjectIdentifier
        let top: CGFloat
        let bottom: CGFloat
    }

    private static func pages(in view: NSView) -> [Scroll] {
        wideColumns(in: view).flatMap { [Scroll(id: ObjectIdentifier($0), top: 0, bottom: 0)] + scrolls(in: $0) }
    }

    private static func scrolls(in view: NSView) -> [Scroll] {
        guard !view.isHidden else { return [] }
        var found: [Scroll] = []
        if let scroll = view as? NSScrollView, let document = scroll.documentView, scroll.frame.height > 0 {
            let visible = scroll.contentView.bounds
            found.append(Scroll(id: ObjectIdentifier(scroll), top: visible.minY, bottom: document.frame.height - visible.maxY))
        }
        return found + view.subviews.flatMap(scrolls)
    }

    private static func kept(_ before: [Scroll], _ after: [Scroll]) -> Bool {
        before.map(\.id) == after.map(\.id) && zip(before, after).allSatisfy { abs($0.top - $1.top) <= 1 || abs($0.bottom - $1.bottom) <= 1 }
    }

    private static func columns(in view: NSView) -> (main: WideColumnView?, side: WideColumnView?) {
        let all = wideColumns(in: view)
        return (all.first { $0.column == .main }, all.first { $0.column == .side })
    }

    private static func wideColumns(in view: NSView) -> [WideColumnView] {
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

    init(_ columns: (main: WideColumnView?, side: WideColumnView?)) { column = columns.main }

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
#endif
