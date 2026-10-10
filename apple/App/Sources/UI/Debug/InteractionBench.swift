#if os(macOS) && DEBUG
import AppKit
import CueStore
import Darwin
import QuartzCore

/// `-CuePadBench interact`：单次交互那一下的主线程耗时，逐项与预算（docs/development.md「交互预算」）比较，
/// 每项结果作为一行 `INTERACT {json}` 打到标准输出，量完退出。配 `-CuePadDemo YES`（演示库）或 `-CuePadSeed perf`（大库）。
/// 动作就是点击、快捷键最终调用的工作区方法（`show`、`openCard`、`toggle`、`toggleSidebar`），不经事件投递（那一段只有 1～5ms）。
/// - **点击回合**：动作发出到主线程第一次回到空闲（SwiftUI 更新、布局、提交都在里面）的主线程 CPU 毫秒，只取第一圈 ≥2ms 的 run loop；
///   CPU 时间不随机器忙闲变，墙钟会。
/// - **掉帧**：动作后 800ms 内窗口 display link 相邻两次回调间隔超过 1.5 帧的次数与最长一次（毫秒）。
/// 开头把本实例调到前台：后台量的数字偏乐观（前台才有玻璃等实际合成），所以会抢一下焦点，量完退出。
@MainActor
enum InteractionBench {
    /// 每项的预算：点击回合上限（毫秒）与掉帧次数上限。预算是目标，不是现状：没达到的项如实报超预算，不改数字迁就。
    /// 依据：144Hz 一帧 6.9ms；对点击的回应在两帧（14ms）内人感觉是"跟手"，要建内容的在四帧（28ms）内不觉得顿；掉帧最多两次。
    /// 回访页面、收起、关闭只是换可见性，对点击要跟手；首访、打开、会话页要建视图，给四帧。
    private static let budgets: [String: (clickMs: Double, hitches: Int)] = [
        "页面回访": (14, 1),
        "页面首访": (28, 2),
        "Agent 页首访": (28, 2),
        "会话页": (28, 2),
        "开纸页": (28, 2),
        "收纸页": (14, 2),
        "任务面板开": (28, 2),
        "任务面板关": (14, 2),
        "⌘K 面板开": (28, 2),
        "⌘K 面板关": (14, 2),
        "侧栏收起": (28, 2),
        "侧栏展开": (28, 2),
    ]

    private static let turns = TurnLog()

    static func run(_ workspace: Workspace) async {
        if PerfProbe.firstSeen["content"] == nil { await PerfProbe.wait(for: "content") {} }
        if UserDefaults.standard.bool(forKey: "CuePadDemo") { await DebugScene.seedRemote(workspace.services) }
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.styleMask.contains(.resizable) }),
              let view = window.contentView
        else { return }
        // 前台才有玻璃等实际合成，后台量的数字偏乐观
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        let store = workspace.services.store
        let projects = (workspace.catalog?.projects ?? []).map(\.id)
        let sessions = ((try? await store.piSessionPage(PiSessionQuery(limit: 3)))?.items ?? []).map(\.state.sessionID)
        func step(_ name: String, _ action: () -> Void) async {
            let row = await measure(name, in: view, action)
            print("INTERACT " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
        let a = projects.indices.contains(1) ? projects[1] : nil, b = projects.indices.contains(2) ? projects[2] : nil
        // 页面：第一次去是首访，之后来回是回访
        if let a { await step("页面首访") { workspace.show(.project(a)) } }
        if let b { await step("页面首访") { workspace.show(.project(b)) } }
        if let a, let b {
            for _ in 0..<2 {
                await step("页面回访") { workspace.show(.project(a)) }
                await step("页面回访") { workspace.show(.project(b)) }
            }
        }
        await step("Agent 页首访") { workspace.show(.agent) }
        if let a { await step("页面回访") { workspace.show(.project(a)) } }
        await step("页面回访") { workspace.show(.agent) }
        for id in sessions.prefix(2) { await step("会话页") { workspace.show(.session(id)) } }
        if let a { await step("页面回访") { workspace.show(.project(a)) } }
        if let card = try? await store.cards(in: workspace.currentProject).first?.id {
            for _ in 0..<2 {
                await step("开纸页") { workspace.openCard = card }
                await step("收纸页") { workspace.openCard = nil }
            }
        }
        for _ in 0..<2 {
            await step("任务面板开") { workspace.showsTasks = true }
            await step("任务面板关") { workspace.showsTasks = false }
            await step("⌘K 面板开") { workspace.searching = true }
            await step("⌘K 面板关") { workspace.searching = false }
        }
        // 侧栏开合在卡最多的项目页上量：整页内容要跟着详情区的宽度重排
        if let big = workspace.catalog?.cardCounts.filter({ $0.key != nil }).max(by: { $0.value < $1.value })?.key {
            await step("页面回访") { workspace.show(.project(big)) }
            for _ in 0..<2 {
                await step("侧栏收起") { workspace.toggleSidebar() }
                await step("侧栏展开") { workspace.toggleSidebar() }
            }
        }
        NSApp.terminate(nil)
    }

    private static func measure(_ name: String, in view: NSView, _ action: () -> Void) async -> [String: Any] {
        try? await Task.sleep(for: .milliseconds(900))
        let recorder = FrameRecorder()
        recorder.start(in: view)
        let started = CACurrentMediaTime()
        turns.begin(started)
        action()
        try? await Task.sleep(for: .milliseconds(800))
        let log = turns.finish()
        let frames = recorder.stop()
        let click = log.first { $0.dur >= 0.002 }
        let budget = budgets[name]
        return [
            "name": name,
            // CPU 不会比墙钟长：第一圈若在量之前就醒了，CPU 里带着量之前的那一段
            "clickMs": (min(click?.cpu ?? 0, click?.dur ?? 0) * 10_000).rounded() / 10,
            "hitches": frames["hitches"] ?? 0,
            "worstMs": frames["worstFrameMs"] ?? 0,
            "budgetClickMs": budget?.clickMs ?? 0,
            "budgetHitches": budget?.hitches ?? 0,
        ]
    }
}

/// 每圈主线程 run loop（醒来 → 回去睡）的墙钟与 CPU 时间；提交发生在这一圈的 BeforeWaiting，所以一圈包含一帧的更新、布局与提交。
@MainActor
private final class TurnLog {
    struct Turn {
        var dur: CFTimeInterval
        var cpu: Double
    }

    private let port = mach_thread_self()
    private var woke: CFTimeInterval = 0
    private var wokeCPU = 0.0
    private var since: CFTimeInterval = 0
    private var log: [Turn] = []
    private var recording = false

    init() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated {
                self.woke = CACurrentMediaTime()
                self.wokeCPU = self.cpu()
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                guard self.recording else { return }
                self.log.append(Turn(dur: CACurrentMediaTime() - max(self.woke, self.since), cpu: self.cpu() - self.wokeCPU))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }

    private func cpu() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    func begin(_ time: CFTimeInterval) {
        log = []
        since = time
        recording = true
    }

    func finish() -> [Turn] {
        recording = false
        return log
    }
}
#endif
