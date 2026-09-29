import Foundation
import Synchronization
import Testing

@testable import CueDispatch

/// 内存实现共用一份事件日志：断言的是跨协作者的顺序，这是投送队列的对外合同。
final class Log: Sendable {
    private let events = Mutex<[(String, ContinuousClock.Instant)]>([])
    func add(_ event: String) { events.withLock { $0.append((event, .now)) } }
    var names: [String] { events.withLock { $0.map(\.0) } }
    var entries: [(name: String, at: ContinuousClock.Instant)] { events.withLock { $0.map { ($0.0, $0.1) } } }
}

final class FakeApps: AppDirectory {
    let log: Log
    let last: AppInfo?
    let running: [AppInfo]
    /// nil 表示 activate 后永远不发激活通知。
    let activationDelay: Duration?
    let subscribers = Mutex<[AsyncStream<pid_t>.Continuation]>([])
    let active = Mutex<pid_t?>(nil)

    init(_ log: Log, last: AppInfo? = nil, running: [AppInfo] = [], activationDelay: Duration? = .milliseconds(20)) {
        self.log = log
        self.last = last
        self.running = running
        self.activationDelay = activationDelay
    }

    func lastFrontmost() -> AppInfo? { last }
    func app(pid: pid_t) -> AppInfo? { (running + [last].compactMap { $0 }).first { $0.pid == pid } }
    func runningApp(bundleID: String) -> AppInfo? { running.first { $0.bundleID == bundleID } }
    func isActive(pid: pid_t) -> Bool { active.withLock { $0 == pid } }
    func activations() -> AsyncStream<pid_t> {
        AsyncStream { continuation in subscribers.withLock { $0.append(continuation) } }
    }

    func activate(pid: pid_t) -> Bool {
        log.add("activate")
        guard let delay = activationDelay else { return true }
        Task {
            try? await Task.sleep(for: delay)
            active.withLock { $0 = pid }
            log.add("activated")
            for subscriber in subscribers.withLock({ $0 }) { subscriber.yield(pid) }
        }
        return true
    }
}

struct FakeClipboard: ClipboardWriting {
    let log: Log
    func write(_ payload: Payload) { log.add("clip:\(payload.plainText)") }
}

struct FakeKeys: KeyPosting {
    let log: Log
    func preflight() { log.add("preflight") }
    func post(_ key: Keystroke, to pid: pid_t) { log.add("\(key):\(pid)") }
}

private let editor = AppInfo(pid: 10, bundleID: "com.apple.TextEdit", name: "TextEdit")
private let terminal = AppInfo(pid: 20, bundleID: "com.apple.Terminal", name: "Terminal")
private let fast = Timing(activationTimeout: .milliseconds(200), pasteSettle: .milliseconds(50))

private func makeDispatcher(_ log: Log, apps: FakeApps, trusted: Bool = true) -> Dispatcher {
    Dispatcher(apps: apps, clipboard: FakeClipboard(log: log), keys: FakeKeys(log: log), isTrusted: { trusted }, timing: fast)
}

@Suite struct DispatcherTests {
    @Test func 顺序为预检写剪贴板激活等通知粘贴回车() async throws {
        let log = Log()
        let dispatcher = makeDispatcher(log, apps: FakeApps(log, last: editor))
        try await dispatcher.dispatch(Payload(text: "a"), to: .lastFrontmost, submit: true)
        #expect(log.names == ["preflight", "clip:a", "activate", "activated", "paste:10", "return:10"])
    }

    @Test func 连续投送严格串行且粘贴后留消费窗口() async {
        let log = Log()
        let dispatcher = makeDispatcher(log, apps: FakeApps(log, last: editor))
        await withThrowingTaskGroup(of: Void.self) { group in
            for text in ["a", "b", "c"] { group.addTask { try await dispatcher.dispatch(Payload(text: text), to: .lastFrontmost) } }
        }
        let entries = log.entries.filter { $0.name.hasPrefix("clip:") || $0.name == "paste:10" }
        // 每次写剪贴板都紧跟自己的粘贴，不与其他投送交错
        #expect(entries.map { $0.name.hasPrefix("clip:") } == [true, false, true, false, true, false])
        // 粘贴到下一次改写剪贴板之间不短于消费窗口
        for i in stride(from: 1, to: entries.count - 1, by: 2) {
            #expect(entries[i + 1].at - entries[i].at >= fast.pasteSettle)
        }
    }

    @Test func 未授权辅助功能时不碰剪贴板() async {
        let log = Log()
        let dispatcher = makeDispatcher(log, apps: FakeApps(log, last: editor), trusted: false)
        await #expect(throws: DispatchError.accessibilityRequired) {
            try await dispatcher.dispatch(Payload(text: "a"), to: .lastFrontmost)
        }
        #expect(log.names.isEmpty)
    }

    @Test func 指定应用未运行时明确报错且不回退到上一个前台应用() async {
        let log = Log()
        let dispatcher = makeDispatcher(log, apps: FakeApps(log, last: editor))
        await #expect(throws: DispatchError.targetUnavailable) {
            try await dispatcher.dispatch(Payload(text: "a"), to: .terminal)
        }
        #expect(log.names.isEmpty)
    }

    @Test func 没有上一个前台应用时报无目标() async {
        let log = Log()
        let dispatcher = makeDispatcher(log, apps: FakeApps(log))
        await #expect(throws: DispatchError.noTarget) {
            try await dispatcher.dispatch(Payload(text: "a"), to: .lastFrontmost)
        }
    }

    @Test func 激活通知超时则不发送按键() async {
        let log = Log()
        let dispatcher = makeDispatcher(log, apps: FakeApps(log, running: [terminal], activationDelay: nil))
        await #expect(throws: DispatchError.targetUnavailable) {
            try await dispatcher.dispatch(Payload(text: "a"), to: .terminal)
        }
        #expect(!log.names.contains { $0.hasPrefix("paste") })
    }
}
