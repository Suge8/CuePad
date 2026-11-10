import Foundation

extension AppServices {
    /// 不认识的链接忽略。
    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        pendingDeepLink = link
    }

    func consumeDeepLink() -> DeepLink? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    /// 返回的令牌用于注销。
    @discardableResult
    func addBackgroundFlush(_ flush: @escaping @MainActor () async -> Void) -> UUID {
        let token = UUID()
        backgroundFlushes[token] = flush
        return token
    }

    func removeBackgroundFlush(_ token: UUID) {
        backgroundFlushes[token] = nil
    }

    /// App 整个进后台时在后台任务里调用（iOS 最后一个窗口退到后台，`BackgroundWork`；只是一个窗口退下、别的还在前台的不调）。
    /// 本地落盘后先刷新快照，不让网络占完后台时间。通话在后台照常进行，中转为它的信令留着，通话结束时再来一遍（`VoiceService.finish`）。
    func prepareForBackground() async {
        stopPolling()
        if !voice.isLive { relay?.pause() }
        for flush in backgroundFlushes.values { await flush() }
        await resendSnapshots()
        await viewer?.settle()
        await sync?.push()
        // 收下的那一批的门铃由跟随者在 push 返回前排上（同一个主线程队列，先到先跑），这里等它发完；其间回了前台就不断
        await relay?.settle()
        await resendSnapshots()
    }

    /// 返回的等待在语音的订阅、马上上传的几条、跟随者与拉取都收尾后结束（测试等它确认放掉了资料库；退出不等）。
    @discardableResult
    func cancelBackgroundWork() -> @Sendable () async -> Void {
        let voice = voice.cancel(), followers = tasks.cancelAll(), polling = polling, sending = inFlight.settled()
        stopPolling()
        return {
            await sending()
            for task in voice { await task.value }
            await followers()
            await polling?.value
        }
    }
}
