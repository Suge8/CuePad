import Foundation

extension AppServices {
    typealias HaltStep = (name: String, run: @Sendable () async throws -> Void)

    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        pendingDeepLink = link
    }

    func consumeDeepLink() -> DeepLink? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    @discardableResult
    func addBackgroundFlush(_ flush: @escaping @MainActor () async -> Void) -> UUID {
        let token = UUID()
        backgroundFlushes[token] = flush
        return token
    }

    func removeBackgroundFlush(_ token: UUID) {
        backgroundFlushes[token] = nil
    }

    func prepareForBackground() async {
        syncing.stopPolling()
        if !voice.isLive { relay?.pause() }
        for flush in backgroundFlushes.values { await flush() }
        await resendSnapshots()
        await viewer.settle()
        await sync?.push()
        await relay?.settle()
        await resendSnapshots()
    }

    func halt() -> (steps: [HaltStep], stopSync: @Sendable () async -> Void, followers: Task<Void, Never>?) {
        let followers = cancelBackgroundWork(), sync = sync
        var steps: [HaltStep] = []
        #if os(macOS)
        steps += [("远程投送执行器", executor.beginStop()), ("Cue", cue.stop())]
        #endif
        return (steps, { await sync?.stop() }, followers)
    }

    @discardableResult
    func cancelBackgroundWork() -> Task<Void, Never>? {
        voice.cancel()
        syncing.stopPolling()
        return tasks.cancelAll()
    }
}
