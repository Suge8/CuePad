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

    /// App 整个进后台时调用（iOS 最后一个窗口退到后台，在后台任务里，`BackgroundWork`；只是一个窗口退下、别的还在前台的不调）：
    /// 停掉按节奏的拉取，等所有登记的落盘完成，写下这台设备已离开会话（界面在场景退到后台时报的）并传完，
    /// 本地落盘后先刷新快照，不让网络占完后台时间；再发完待推送、等门铃按完后断开中转，最后补上上传后的状态。
    /// 回前台的对应入口是 `handleActivation`。
    func prepareForBackground() async {
        stopPolling()
        relay?.pause()
        for flush in backgroundFlushes.values { await flush() }
        await resendSnapshots()
        await viewer?.settle()
        await sync?.push()
        // 收下的那一批的门铃由跟随者在 push 返回前排上（同一个主线程队列，先到先跑），这里等它发完；其间回了前台就不断
        await relay?.settle()
        await resendSnapshots()
    }

    /// 取消后台任务（快照维护、分享入库、macOS 的 Pi 索引等）。
    func cancelBackgroundWork() {
        tasks.cancelAll()
        stopPolling()
    }
}
