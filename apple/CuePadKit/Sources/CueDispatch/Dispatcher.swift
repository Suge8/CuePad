import Foundation

/// 单一串行队列：预检 → 写剪贴板 → 激活目标 → 等激活通知 → 定向 Cmd+V → 可选回车 → 消费窗口。
/// actor 在 await 处可重入，顺序由 `tail` 任务链保证，而不是 actor 互斥。
/// 窗口隐藏与发送记录由调用方负责：本模块只返回目标应用或错误码。
public actor Dispatcher {
    private let apps: any AppDirectory
    private let clipboard: any ClipboardWriting
    private let keys: any KeyPosting
    private let isTrusted: @Sendable () -> Bool
    private let timing: Timing
    private var tail: Task<Void, Never> = Task {}

    public init(
        apps: any AppDirectory,
        clipboard: any ClipboardWriting,
        keys: any KeyPosting,
        isTrusted: @escaping @Sendable () -> Bool,
        timing: Timing = Timing()
    ) {
        self.apps = apps
        self.clipboard = clipboard
        self.keys = keys
        self.isTrusted = isTrusted
        self.timing = timing
    }

    @discardableResult
    public func dispatch(_ payload: Payload, to selector: TargetSelector, submit: Bool = false) async throws(DispatchError) -> AppInfo {
        let previous = tail
        let job = Task { () -> Result<AppInfo, DispatchError> in
            await previous.value
            do throws(DispatchError) { return .success(try await perform(payload, selector, submit)) } catch { return .failure(error) }
        }
        tail = Task { _ = await job.value }
        return try await job.value.get()
    }

    public func resolve(_ selector: TargetSelector) throws(DispatchError) -> AppInfo {
        switch selector {
        case .bundleID(let id):
            guard let app = apps.runningApp(bundleID: id) else { throw .targetUnavailable }
            return app
        case .lastFrontmost:
            guard let last = apps.lastFrontmost() else { throw .noTarget }
            // pid 可能已被别的进程复用：bundle id 不符视为目标已退出
            guard let app = apps.app(pid: last.pid), last.bundleID == nil || last.bundleID == app.bundleID else {
                throw .targetUnavailable
            }
            return app
        }
    }

    private func perform(_ payload: Payload, _ selector: TargetSelector, _ submit: Bool) async throws(DispatchError) -> AppInfo {
        guard isTrusted() else { throw .accessibilityRequired }
        let target = try resolve(selector)
        try keys.preflight()
        try clipboard.write(payload)
        try await activate(target)
        try keys.post(.paste, to: target.pid)
        try? await Task.sleep(for: timing.pasteSettle)
        if submit { try keys.post(.return, to: target.pid) }
        return target
    }

    private func activate(_ target: AppInfo) async throws(DispatchError) {
        if apps.isActive(pid: target.pid) { return }
        let activations = apps.activations()
        guard apps.activate(pid: target.pid) else { throw .targetUnavailable }
        if apps.isActive(pid: target.pid) { return }
        let timeout = timing.activationTimeout
        let activated = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await pid in activations where pid == target.pid { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        guard activated else { throw .targetUnavailable }
    }
}
