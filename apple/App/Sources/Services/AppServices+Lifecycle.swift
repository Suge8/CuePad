import Foundation

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

    /// 进入后台前调用（在后台任务里，`BackgroundWork`）：等所有登记的落盘完成，写下这台设备已离开会话（界面在场景退到后台时报的）并传完，
    /// 把待推送发完（挂起后发送者就不会再跑了），等这些改动的门铃按完再断开中转，并把小组件快照刷到最新（观察任务同理）。
    func prepareForBackground() async {
        stopPolling()
        relay?.pause()
        for flush in backgroundFlushes.values { await flush() }
        await viewer?.settle()
        await sync?.push()
        // 收下的那一批的门铃由跟随者在 push 返回前排上（同一个主线程队列，先到先跑），这里等它发完；其间回了前台就不断
        await relay?.settle()
        do {
            try await writeSnapshots(resend: true)
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
