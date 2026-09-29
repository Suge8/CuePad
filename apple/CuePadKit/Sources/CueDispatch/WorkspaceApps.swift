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
        if let front = NSWorkspace.shared.frontmostApplication { record(AppInfo(front)) }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.record(AppInfo(app))
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

    /// 目标选择器用的运行中应用：普通应用、去重、按名称排序。
    public func runningTargets() -> [AppInfo] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .map(AppInfo.init)
            .filter { app in !isExcluded(app) && app.bundleID.map { seen.insert($0).inserted } == true }
            .sorted { $0.name < $1.name }
    }

    private func record(_ app: AppInfo) {
        let subscribers = state.withLock { state in
            if app.pid >= 0, !isExcluded(app) { state.last = app }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(app.pid) }
    }

    private func isExcluded(_ app: AppInfo) -> Bool {
        app.pid == excludedPID || (excludedBundleID != nil && app.bundleID == excludedBundleID)
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
