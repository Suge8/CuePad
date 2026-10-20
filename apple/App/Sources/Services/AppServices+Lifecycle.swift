import Foundation

/// 深链接与进入后台前的落盘。
extension AppServices {
    /// 小组件、分享扩展的链接；不认识的链接忽略。
    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        pendingDeepLink = link
    }

    func consumeDeepLink() -> DeepLink? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    /// 界面登记进入后台前必须落盘的内容（如编辑中的草稿）。返回的令牌用于注销。
    @discardableResult
    func addBackgroundFlush(_ flush: @escaping @MainActor () async -> Void) -> UUID {
        let token = UUID()
        backgroundFlushes[token] = flush
        return token
    }

    func removeBackgroundFlush(_ token: UUID) {
        backgroundFlushes[token] = nil
    }

    /// 进入后台前调用：等所有登记的落盘完成，写下这台设备已离开会话（界面在场景退到后台时报的）并传完，把待推送发完（挂起后发送者就不会再跑了），并把小组件快照刷到最新（观察任务同理）。
    func prepareForBackground() async {
        stopPolling()
        for flush in backgroundFlushes.values { await flush() }
        await viewer?.settle()
        await sync?.push()
        do {
            try await writeSnapshots()
        } catch {
            reportIssue(.widgetDataUnavailable("\(error)"))
        }
    }

    /// 取消后台任务（快照维护、分享入库、macOS 的 Pi 索引等）。
    func cancelBackgroundWork() {
        tasks.cancelAll()
        stopPolling()
    }
}
