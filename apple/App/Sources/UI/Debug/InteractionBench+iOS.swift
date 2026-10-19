#if os(iOS) && DEBUG
import CueEditor
import CueStore
import Darwin
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// iOS 的 `-CuePadBench interact`（配 `-CuePadDemo YES`，iPhone：以去处为根的导航栈加底部一排）：单次交互那一下的主线程耗时，口径同 Mac 的 `InteractionBench`，
/// 每项一行 `INTERACT {json}` 写进隔离库目录下的 `interact.jsonl`（模拟器里的标准输出不好取），量完退出。
/// 动作是点击最终调用的同一条路（导航路径、`openSession`、点底部那一排与侧栏的 `select`、浮窗与面板的状态），不经触摸投递。
/// 长按菜单在进程内没有入口：由 `perf-ios.sh` 在模拟器上真按（`AWAIT` 行），从手指按下起量。每项至少做两遍：第一遍是首次（要现建视图），之后是再次。
/// 演示库缺了要量的东西时写 `FAIL 原因` 并以 1 退出；全部量完写 `DONE`。`-CuePadInteractOnly 项,项` 只量列出的几项（同 Mac）。
/// - 冷启动·Cue 页：App 一打开就在 Cue 页上；`launchMs` 是进程启动到对话排出来（`PerfProbe` 的 `cue`）的墙钟毫秒，
///   主线程与帧从画面摆起来（`beginCold`）量到对话出来后一秒，指令数从进程启动算起。量真实大小的对话配 `CUEPAD_PERF_SEED`（`perf-ios.sh`）。
/// - 长文粘贴、长文打字：输入框（回复框、对 Cue 说）经剪贴板粘贴进一大段（诊断 JSON 那样，`pasted`），之后再敲一个字，
///   走键盘输入同一条路（`paste`、`UITextInput.insertText`），每个字一项；编辑页是正文已有那一大段时打字。`-CuePadPasteFile <路径>` 换成那个文件的内容。
/// - 点击回合：动作发出到主线程第一次回到空闲的主线程 CPU 毫秒（只取第一圈 ≥2ms 的 run loop）。
/// - 合计、最重一圈：动作后 800ms 里主线程 CPU 的总数与最重的一圈；指令数（百万条）是进程在这 800ms 里执行的，不随机器忙闲变。
/// - 掉帧：display link 相邻间隔超过 1.5 帧的次数。模拟器的合成与 GPU 和真机不同，只作参考。
enum IOSInteractionBench {
    private static let turns = TurnLog()
    private static let coldFrames = FrameRecorder()

    /// 画面一摆起来就开始量冷启动（`DebugScene.prepare` 的第一步），读库与摆画面都在它之后。
    static func beginCold() {
        coldFrames.start()
        turns.begin(CACurrentMediaTime(), root: nil)
    }

    private static func cold() async -> [String: Any] {
        if PerfProbe.firstSeen["cue"] == nil { await PerfProbe.wait(for: "cue") }
        try? await Task.sleep(for: .seconds(1))
        var row = TurnLog.metrics(turns.finish(), instructions: 0, frames: coldFrames.stop())
        row["launchMs"] = ((PerfProbe.firstSeen["cue"] ?? .now).timeIntervalSince(PerfProbe.processStart) * 1000).rounded()
        row["name"] = "冷启动·Cue 页"
        return row
    }

    static func run(_ workspace: Workspace, _ navigation: Navigation) async {
        guard let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        let out = URL(filePath: dir).appending(path: "interact.jsonl")
        try? Data().write(to: out)
        func write(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: out) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
        /// 缺了要量的东西就整次作废：不悄悄少量几项
        func fail(_ reason: String) -> Never {
            write("FAIL " + reason)
            exit(1)
        }
        let only = UserDefaults.standard.string(forKey: "CuePadInteractOnly").map { Set($0.split(separator: ",").map(String.init)) }
        func wants(_ name: String) -> Bool { only?.contains(name) ?? true }
        func row(_ row: [String: Any]) { write("INTERACT " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)) }
        let cold = await cold()
        if wants("冷启动·Cue 页") { row(cold) }
        // 只量冷启动时不要求库里有别的项（真实库的副本不一定有演示库那几样）
        if only == ["冷启动·Cue 页"] {
            write("DONE")
            exit(0)
        }
        try? await Task.sleep(for: .seconds(3))
        let store = workspace.services.store
        let projects = (workspace.catalog?.projects ?? []).map(\.id)
        let sessions = ((try? await store.piSessionPage(PiSessionQuery(limit: 4)))?.items ?? []).map(\.state.id)
        let tasks = ((try? await store.tasks(.inProgress, .todo))?.flatMap(\.tasks) ?? []).filter { $0.parentID == nil }.map(\.id)
        guard projects.count >= 2 else { fail("演示库里不到两个项目") }
        guard sessions.count >= 2 else { fail("演示库里不到两个会话") }
        guard let task = tasks.first else { fail("演示库里没有任务") }
        guard let idea = try? await store.cards(in: nil).first else { fail("演示库里没有未分类的灵感") }
        /// `press`：请测量脚本在这一点真按（长按或轻点由脚本按名字定），从手指按下起量；不给时从 `action` 发出起量。
        func step(_ name: String, window: Duration = .milliseconds(800), press: CGPoint? = nil, _ action: () -> Void = {}) async {
            guard wants(name) else { return }
            let pressed: (() async -> Void)? = press.map { point in { await Self.touch(write, name, at: point) } }
            var measured = await measure(window: window, pressed: pressed, action)
            measured["name"] = name
            row(measured)
        }
        navigation.select(.shelf)
        try? await Task.sleep(for: .seconds(1))
        // 书架点项目（推入项目页）→ 返回；同一个项目两遍，另一个项目再一遍
        for id in [projects[0], projects[0], projects[1]] {
            await step("书架点项目") { navigation.push(.project(id)) }
            await step("返回书架") { navigation.path.removeAll() }
        }
        // 项目页任务纸点"还有 N 条"展开、再收起：在没做完的任务最多的项目上（配 `-CuePadManyTasks` 量任务多时）
        guard let busiest = workspace.catalog?.openTasks.filter({ $0.key != nil }).max(by: { $0.value < $1.value })?.key else { fail("演示库里没有带任务的项目") }
        navigation.push(.project(busiest))
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<2 {
            await step("展开任务") { DebugScene.toggleTaskFold() }
            await step("收起任务") { DebugScene.toggleTaskFold() }
        }
        navigation.select(.cue)
        try? await Task.sleep(for: .seconds(1))
        // 主导航：Cue 页点底部的去处去任务（配 `-CuePadManyTasks` 量任务多时）、任务页点 Cue 圆钮回来（点按调的就是 `select`，过渡由 `DockRoot` 接着做）
        for _ in 0..<2 {
            await step("Cue 进任务") { navigation.select(.tasks) }
            await step("任务回 Cue") { navigation.select(.cue) }
        }
        // Cue 页头开合面板（点页头的那条路）
        for _ in 0..<2 {
            await step("展开 Cue 面板") { DebugScene.toggleCuePanel() }
            await step("收起 Cue 面板") { DebugScene.toggleCuePanel() }
        }
        // 会话页（底部的"会话"）点会话（先读出这一页再推入）→ 返回
        navigation.select(.agent)
        try? await Task.sleep(for: .seconds(1))
        for id in [sessions[0], sessions[0], sessions[1]] {
            await step("进会话页") { navigation.openSession(id, store: store) }
            await step("返回 Agent") { navigation.path.removeAll() }
        }
        // Agent 列表滚动：每帧 40pt 往下再往上
        guard let scroll = Self.scrollView(in: Self.window) else { fail("Agent 页上找不到可滚的列表") }
        for _ in 0..<2 { await stepScroll("Agent 列表滚动", scroll, step: { name, action in await step(name, action) }) }
        navigation.select(.shelf)
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<2 {
            await step("打开任务页") { navigation.push(.card(task)) }
            await step("返回（任务页）") { navigation.path.removeAll() }
        }
        await typeLong(workspace, navigation, session: sessions[0], card: idea.id, wants: wants, fail: fail, step: { name, action in await step(name, action) })
        // 最后量长按书架上的项目卡（放在最后：万一菜单没收起，不影响前面各项）：系统的长按菜单在进程内没有入口，由 perf-ios.sh 在模拟器上真按（`AWAIT 名 x y` 是要它按的点，屏幕坐标）。
        // 从手指按下起量 1.5 秒（菜单在按住约半秒后才弹出）；松手后菜单留着，请脚本点一下空白处收起
        navigation.select(.shelf)
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<2 where wants("长按菜单") {
            guard let card = Self.longPressTarget(in: Self.window) else { fail("书架上找不到有长按菜单的项目卡") }
            await step("长按菜单", window: .milliseconds(1500), press: card)
            // 收起菜单不量（模拟器里点空白处、按 Esc 都收不起长按出来的菜单）：在进程里让菜单交互收起
            Self.dismissMenus(in: Self.window)
            try? await Task.sleep(for: .seconds(2))
        }
        write("DONE")
        exit(0)
    }

    /// 粘贴进来的一大段：仿诊断 JSON（嵌套的调用栈帧，约 850 行、66 KB），或 `-CuePadPasteFile <路径>` 那个文件。
    private static var pasted: String {
        if let path = UserDefaults.standard.string(forKey: "CuePadPasteFile"), let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
        func frame(_ depth: Int) -> [String: Any] {
            var node: [String: Any] = [
                "binaryUUID": "2B62913E-C889-35F4-98D9-FAC049B8284A", "offsetIntoBinaryTextSegment": 46132, "sampleCount": 1, "binaryName": "CuePad",
                "address": 4_378_998_836,
            ]
            if depth > 0 { node["subFrames"] = [frame(depth - 1)] }
            return node
        }
        let stacks = (0..<4).map { _ in ["threadAttributed": false, "callStackRootFrames": [frame(22)]] as [String: Any] }
        let tree = ["crashDiagnostics": [["callStackTree": ["callStacks": stacks]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    /// 长文打字：编辑页的正文先写成 `pasted`；输入框（空着）拿到键盘后经剪贴板粘贴进 `pasted`（量这一下：长文粘贴），
    /// 再一个字一个字地敲（每个字一项）。
    private static func typeLong(
        _ workspace: Workspace, _ navigation: Navigation, session: UUID, card: UUID, wants: (String) -> Bool, fail: (String) -> Never,
        step: (String, () -> Void) async -> Void
    ) async {
        let text = pasted
        func type<View: UITextView>(_ field: String, into _: View.Type, pastes: Bool = true) async {
            try? await Task.sleep(for: .seconds(2))
            guard let view = Self.first(View.self, in: Self.window) else { fail("\(field)：找不到输入框") }
            view.becomeFirstResponder()
            try? await Task.sleep(for: .seconds(1.5))
            if pastes {
                UIPasteboard.general.string = text
                await step("长文粘贴·" + field) { view.paste(nil) }
            }
            view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
            for _ in 0..<5 { await step("长文打字·" + field) { view.insertText("a") } }
            view.resignFirstResponder()
            try? await Task.sleep(for: .seconds(1))
        }
        if wants("长文打字·编辑页") {
            // 从它所在的未分类页推入（同点开它的那条路）：直接从书架推入时 UIKit 的交互转场断言崩溃
            try? await workspace.services.store.updateCard(card) { $0.body = text }
            navigation.select(.unfiled)
            try? await Task.sleep(for: .seconds(1.5))
            navigation.push(.card(card))
            await type("编辑页", into: CueTextView.self, pastes: false)
            navigation.path.removeAll()
        }
        if wants("长文打字·回复框") || wants("长文粘贴·回复框") {
            navigation.select(.cue)
            navigation.openSession(session, store: workspace.services.store)
            await type("回复框", into: GrowingTextView.self)
            workspace.services.settings.setReplyDraft(ComposerDraft(), for: session)
            navigation.path.removeAll()
        }
        if wants("长文打字·对 Cue 说") || wants("长文粘贴·对 Cue 说") {
            navigation.select(.cue)
            await type("对 Cue 说", into: GrowingTextView.self)
            workspace.cue.draft = ComposerDraft()
        }
    }

    private static func first<View: UIView>(_ type: View.Type, in view: UIView?) -> View? {
        guard let view, !view.isHidden else { return nil }
        if let found = view as? View, found.window != nil { return found }
        for sub in view.subviews { if let found = first(type, in: sub) { return found } }
        return nil
    }

    /// 请测量脚本在 `point` 真按一下（长按或轻点由脚本按名字定），等手指按下那一刻再返回：量从按下起算。
    private static func touch(_ write: @escaping (String) -> Void, _ name: String, at point: CGPoint) async {
        await withCheckedContinuation { continuation in
            TouchProbe.arm { continuation.resume() }
            write("AWAIT \(name) \(Int(point.x)) \(Int(point.y))")
        }
    }

    private static func menuInteractions(in view: UIView?) -> [UIInteraction] {
        guard let view else { return [] }
        let here = view.interactions.filter { $0 is UIContextMenuInteraction || String(describing: type(of: $0)).contains("ClickPresentation") }
        return here + view.subviews.flatMap { menuInteractions(in: $0) }
    }

    /// 收起开着的长按菜单：系统的菜单交互收起，SwiftUI 的点按呈现交互取消。
    private static func dismissMenus(in view: UIView?) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for interaction in windows.flatMap({ menuInteractions(in: $0) }) {
            if let menu = interaction as? UIContextMenuInteraction { menu.dismissMenu() } else {
                let cancel = NSSelectorFromString("cancelInteraction")
                if interaction.responds(to: cancel) { interaction.perform(cancel) }
            }
        }
    }

    /// 书架上带长按菜单的项目卡（SwiftUI 的长按菜单在视图上挂着点按呈现交互）的中心点，屏幕坐标。
    private static func longPressTarget(in view: UIView?) -> CGPoint? {
        guard let view, !view.isHidden, view.alpha > 0, let window = view.window ?? (view as? UIWindow) else { return nil }
        let menu = view.interactions.contains { String(describing: type(of: $0)).contains("ClickPresentation") }
        let frame = view.convert(view.bounds, to: window)
        if menu, frame.width > 100, frame.height > 40, window.bounds.contains(frame) { return CGPoint(x: frame.midX, y: frame.midY) }
        for sub in view.subviews { if let found = longPressTarget(in: sub) { return found } }
        return nil
    }

    private static func stepScroll(_ name: String, _ scroll: UIScrollView, step: (String, () -> Void) async -> Void) async {
        // 滚动是持续的：量 40 帧里每帧的主线程回合与掉帧（动作只触发第一帧，之后由 display link 推）
        let driver = ScrollDriver(scroll)
        await step(name) { driver.start() }
        driver.stop()
        scroll.setContentOffset(.zero, animated: false)
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    private static func scrollView(in view: UIView?) -> UIScrollView? {
        guard let view else { return nil }
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height, !view.isHidden, view.window != nil,
           scroll.bounds.height > 300 { return scroll }
        for sub in view.subviews where !sub.isHidden { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private static func measure(window: Duration, pressed: (() async -> Void)?, _ action: () -> Void) async -> [String: Any] {
        try? await Task.sleep(for: .milliseconds(1200))
        if let pressed { await pressed() }
        let recorder = FrameRecorder()
        recorder.start()
        let wall = Date().timeIntervalSince1970
        let instructions = instructionsMillions()
        turns.begin(CACurrentMediaTime(), root: Self.window?.layer)
        action()
        try? await Task.sleep(for: window)
        var row = TurnLog.metrics(turns.finish(), instructions: instructions, frames: recorder.stop())
        // 动作发出的时刻（与 xctrace 录制对时）
        row["at"] = wall
        return row
    }
}

/// 窗口里手指按下的那一刻（测量脚本在模拟器上真按的长按、轻点）：每个窗口挂一个（长按菜单弹在自己的窗口里），只看不拦，按下就报给等着的一方。
private final class TouchProbe: UIGestureRecognizer {
    private static var waiting: (() -> Void)?

    static func arm(_ pressed: @escaping () -> Void) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchProbe }) {
            let probe = TouchProbe(target: nil, action: nil)
            probe.cancelsTouchesInView = false
            probe.delaysTouchesBegan = false
            probe.delaysTouchesEnded = false
            window.addGestureRecognizer(probe)
        }
        waiting = pressed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Self.waiting?()
        Self.waiting = nil
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// 每帧往下滚 40pt，到底往回。
private final class ScrollDriver: NSObject {
    private let scroll: UIScrollView
    private var link: CADisplayLink?
    private var direction: CGFloat = 1

    init(_ scroll: UIScrollView) { self.scroll = scroll }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate() }

    @objc private func tick() {
        let maxY = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        var y = scroll.contentOffset.y + 40 * direction
        if y >= maxY { y = maxY; direction = -1 } else if y <= -scroll.adjustedContentInset.top { direction = 1 }
        scroll.contentOffset.y = y
    }
}
#endif
