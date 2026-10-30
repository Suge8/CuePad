#if os(macOS)
import CueStore
import Foundation

extension AppServices {
    /// 确认窗口结束后由常规历史索引继续跟随未收尾的文件；路径来自既有索引与请求，不另存一份确认状态。
    func piDeliveryHistoryFiles() -> AsyncStream<Set<URL>> {
        AsyncStream { continuation in
            let task = Task {
                let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let changes = pi.changes()
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in changes { signals.continuation.yield() }
                    }
                    group.addTask { [store, hostID] in
                        do {
                            for try await _ in store.observe({ try $0.deliveryHistoryFiles(on: hostID) }) { signals.continuation.yield() }
                        } catch {
                            if !Task.isCancelled { await self.reportIssue(.piHistoryUnavailable(String(describing: error))) }
                            signals.continuation.finish()
                        }
                    }
                    for await _ in signals.stream {
                        do {
                            let retained = try await store.deliveryHistoryFiles(on: hostID)
                            continuation.yield(Set(pi.slots.compactMap(\.session.sessionFile)).union(retained))
                        } catch {
                            if !Task.isCancelled { reportIssue(.piHistoryUnavailable(String(describing: error))) }
                            break
                        }
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
