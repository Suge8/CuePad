#if os(macOS)
import CueStore
import Foundation
import OSLog

nonisolated enum ShutdownSteps {
    enum Failure: Sendable {
        case timedOut(String)
        case failed(String, String)
    }

    struct UploadUnconfirmed: Error, LocalizedError {
        var errorDescription: String? { "本地记录已写下，但尚未确认云端已接受上传" }
    }

    private enum Event: Sendable {
        case finished(String, String?)
        case deadline
    }

    /// 退出不能等待忽略取消的组件，因此到总预算后取消任务但不 join。
    @concurrent
    static func run(_ steps: [(name: String, run: @Sendable () async throws -> Void)], within limit: Duration) async -> Failure? {
        guard !steps.isEmpty else { return nil }
        let (events, event) = AsyncStream<Event>.makeStream()
        let jobs: [Task<Void, Never>] = steps.map { step in
            Task {
                do {
                    try await step.run()
                    event.yield(.finished(step.name, nil))
                } catch {
                    event.yield(.finished(step.name, error.localizedDescription))
                }
            }
        }
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            event.yield(.deadline)
        }
        defer {
            timer.cancel()
            for job in jobs { job.cancel() }
            event.finish()
        }
        let log = Logger(subsystem: AppIdentity.id, category: "shutdown")
        var pending = Set(steps.map(\.name))
        var firstFailure: Failure?
        for await next in events {
            switch next {
            case .finished(let component, let reason):
                pending.remove(component)
                if let reason {
                    log.error("退出收尾：\(component, privacy: .public) 未完成：\(reason, privacy: .public)")
                    if firstFailure == nil { firstFailure = .failed(component, reason) }
                }
                if pending.isEmpty { return firstFailure }
            case .deadline:
                return steps.first(where: { pending.contains($0.name) }).map { .timedOut($0.name) } ?? firstFailure
            }
        }
        return firstFailure
    }
}
#endif
