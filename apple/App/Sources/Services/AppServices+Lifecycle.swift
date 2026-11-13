import Foundation

extension AppServices {
    typealias HaltStep = (name: String, run: @Sendable () async throws -> Void)

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
        syncing.stopPolling()
        if !voice.isLive { relay?.pause() }
        for flush in backgroundFlushes.values { await flush() }
        await resendSnapshots()
        await viewer?.settle()
        await sync?.push()
        // 收下的那一批的门铃由跟随者在 push 返回前排上（同一个主线程队列，先到先跑），这里等它发完；其间回了前台就不断
        await relay?.settle()
        await resendSnapshots()
    }

    /// 停下这个实例自己的工作：取消跟随者，停执行器、Cue（Mac）与同步。返回各组件的等待（可并行，不需要主线程）与跟随者们的任务。
    /// 不写离线之类的收尾记录：退出（`beginShutdown`）在它之上再写，`syncAfter` 是停同步前要等传完的；测试换实例时只用它，免得晚到的写入盖过新实例的。
    func halt(syncAfter: @escaping @Sendable () async -> Void = {}) -> (steps: [HaltStep], followers: Task<Void, Never>?) {
        let followers = cancelBackgroundWork(), sync = sync
        var steps: [HaltStep] = []
        #if os(macOS)
        steps += [("远程投送执行器", executor.beginStop()), ("Cue", cue.stop())]
        #endif
        steps.append(("同步", {
            await syncAfter()
            await sync?.stop()
        }))
        return (steps, followers)
    }

    /// 返回的是跟随者们的任务（见 `Followers.cancelAll`）。
    @discardableResult
    func cancelBackgroundWork() -> Task<Void, Never>? {
        voice.cancel()
        syncing.stopPolling()
        return tasks.cancelAll()
    }
}
