#if os(macOS)
import AppKit
import Synchronization

/// 订阅 NSWorkspace 激活通知追踪上一个前台应用，不轮询。通知在主队列投递，需要主 run loop 在跑。
public final class WorkspaceApps: AppDirectory, @unchecked Sendable {
    private struct State {
        var last: AppInfo?
        var subscribers: [UUID: AsyncStream<pid_t>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let excludedPID: pid_t
    private let excludedBundleID: String?
    private let center: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    /// `notificationCenter` 默认取 NSWorkspace 的；测试可注入私有中心。
    public init(
        excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        excludedBundleID: String? = nil,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.excludedPID = excludedPID
        self.excludedBundleID = excludedBundleID
        self.center = notificationCenter
        if let front = NSWorkspace.shared.frontmostApplication { record(front) }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.record(app)
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    public func lastFrontmost() -> AppInfo? { state.withLock { $0.last } }

    public func app(pid: pid_t) -> AppInfo? {
        NSRunningApplication(processIdentifier: pid).flatMap { $0.isTerminated ? nil : AppInfo($0) }
    }

    public func runningApp(bundleID: String) -> AppInfo? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }.map(AppInfo.init)
    }

    public func isActive(pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.isActive ?? false }

    public func activate(pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.activate() ?? false }

    public func activations() -> AsyncStream<pid_t> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
            }
        }
    }

    /// 目标选择器用的运行中应用：可投送、去重、按名称排序。
    public func runningTargets() -> [AppInfo] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && isDispatchable($0) }
            .map(AppInfo.init)
            .filter { $0.bundleID.map { seen.insert($0).inserted } == true }
            .sorted { $0.name < $1.name }
    }

    /// 上一个前台应用与目标列表共用的口径：普通应用（排除 loginwindow、Dock、Spotlight 等）且不是被排除者。
    private func isDispatchable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular
            && app.processIdentifier != excludedPID
            && (excludedBundleID == nil || app.bundleIdentifier != excludedBundleID)
    }

    /// 所有激活都通知订阅者（等待目标激活用）；只有可投送应用才更新"上一个前台应用"。
    private func record(_ app: NSRunningApplication) {
        let info = AppInfo(app)
        let dispatchable = isDispatchable(app) && info.pid >= 0
        let subscribers = state.withLock { state in
            if dispatchable { state.last = info }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(info.pid) }
    }
}

extension AppInfo {
    public init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "目标应用")
    }
}
#endif
