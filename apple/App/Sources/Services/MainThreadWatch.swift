import Foundation
import Synchronization

/// 主线程卡住（一轮事件循环超过 `threshold` 没回去等事件）时记下的一条：何时起、在哪一页、之前做了什么。
/// 用户看到的是"整屏冻住、摸哪都没反应，动画还在动"（动画在渲染服务里画），之后多半从后台划掉，系统 5 秒等不到退出就记一份 0x8BADF00D：
/// 那份崩溃只说明退出时主线程在忙，这一条说明它是在哪、做了什么之后卡住的。卡住期间写一次，恢复了再写上时长；没恢复（被结束）就没有时长。
nonisolated struct FreezeNote: Codable, Equatable, Sendable {
    var start: Date
    var seconds: Double?
    var page: String
    var actions: [String]
    var version: String
    var device: String
    var os: String

    /// 与 MetricKit 的包区分（`CrashReport.Kind`）。
    struct File: Codable {
        static let key = "cuepadFreeze"
        let cuepadFreeze: FreezeNote
    }
}

/// 同一轮忙过 `threshold`（1 秒）才记。主线程闲着时看守停着（不为它唤醒）；所在页与最近的动作由界面在变时报来，卡住时看守直接读，不经主线程。
/// 处处都开（调试实例也记：`xc.sh explore` 靠它发现卡住后取样）；只有 MetricKit 订阅限在用户的设备上（`Diagnostics.start`）。
nonisolated final class MainThreadWatch: Sendable {
    static let shared = MainThreadWatch()
    static let threshold: UInt64 = 1_000_000_000
    static let interval = DispatchTimeInterval.milliseconds(500)
    static let recent = 8

    private struct State {
        /// 这一轮醒来的时刻（`DispatchTime` 的纳秒）；0 是在等事件。
        var entered: UInt64 = 0
        var watching = false
        var page = "?"
        var actions: [String] = []
        var open: (entered: UInt64, note: FreezeNote)?
        var archive: DiagnosticArchive?
        var meta = (version: "", device: "", os: "")
        var recorded: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "CuePad.main-thread-watch", qos: .utility)
    private let timer: any DispatchSourceTimer

    private init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(100))
        timer.setEventHandler { [unowned self] in check() }
    }

    /// 幂等。记下的条目存进 `archive`，存下后在主线程调 `recorded`。
    @MainActor
    func start(archive: DiagnosticArchive, version: String, recorded: @escaping @MainActor @Sendable () -> Void) {
        let started = state.withLock { state in
            defer { state.archive = archive }
            state.meta = (version, Self.device, ProcessInfo.processInfo.operatingSystemVersionString)
            state.recorded = { Task { @MainActor in recorded() } }
            return state.archive != nil
        }
        guard !started else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) {
            [unowned self] _, activity in turn(awake: activity == .afterWaiting)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        turn(awake: true)
    }

    func page(_ page: String) { state.withLock { $0.page = page } }

    func action(_ action: String) {
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: false))
        state.withLock { state in
            state.actions.append("\(stamp) \(action)")
            if state.actions.count > Self.recent { state.actions.removeFirst() }
        }
    }

    /// 看守的开停都在锁里：开、停各只在 `watching` 翻转的那一下做一次，挂起与恢复的次数才配得上。
    private func turn(awake: Bool) {
        state.withLock { state in
            state.entered = awake ? DispatchTime.now().uptimeNanoseconds : 0
            guard awake, !state.watching else { return }
            state.watching = true
            timer.resume()
        }
    }

    private func check() {
        let (write, archive, recorded) = state.withLock { state -> (FreezeNote?, DiagnosticArchive?, (@Sendable () -> Void)?) in
            // 在锁里取时刻：锁外取的话主线程可能在取完之后才记下这一轮的醒来，醒来比"此刻"还晚
            let now = DispatchTime.now().uptimeNanoseconds
            var write: FreezeNote?
            if let open = state.open, open.entered != state.entered {
                var note = open.note
                note.seconds = Double(now - open.entered) / 1e9
                write = note
                state.open = nil
            } else if state.open == nil, state.entered != 0, now - state.entered > Self.threshold {
                let note = FreezeNote(
                    start: .now.addingTimeInterval(-Double(now - state.entered) / 1e9), page: state.page, actions: state.actions,
                    version: state.meta.version, device: state.meta.device, os: state.meta.os)
                state.open = (state.entered, note)
                write = note
            }
            if state.entered == 0, state.open == nil {
                state.watching = false
                timer.suspend()
            }
            return (write, state.archive, state.recorded)
        }
        guard let write, let archive else { return }
        do { try archive.store(write) } catch { AppServices.log.error("卡住记录没存下：\(String(describing: error))") }
        recorded?()
    }

    private static var device: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
