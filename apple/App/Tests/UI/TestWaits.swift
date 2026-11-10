import CueTestSupport
import Foundation

/// 等墙钟走过 2 毫秒：库里的时间存到毫秒，要分先后的两次写入之间用它，不睡定长。
func clockTick() async throws {
    let mark = Date.now
    try await eventually("墙钟走过 2 毫秒") { Date.now.timeIntervalSince(mark) >= 0.002 }
}

/// 等流的下一项（满足 `match` 的）；到 `conditionBudget` 还没有就抛错，写明在等什么。先订阅（建好流）、再触发。
@discardableResult
func awaitNext<S: AsyncSequence & Sendable>(
    _ what: String, from stream: S, where match: @escaping @Sendable (S.Element) -> Bool = { _ in true }
) async throws -> S.Element where S.Element: Sendable {
    try await withThrowingTaskGroup(of: S.Element.self) { group in
        group.addTask {
            for try await value in stream where match(value) { return value }
            throw NotArrived(description: "流结束了，没等到：\(what)")
        }
        group.addTask {
            try await Task.sleep(for: conditionBudget)
            throw NotArrived(description: "等不到：\(what)")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// 只让出执行权、不睡：状态在调用方所在的 actor 上同步翻转时，比轮询睡眠更不会错过那一刻。
func yieldUntil(_ what: String, isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + conditionBudget
    while !condition() {
        guard ContinuousClock.now < deadline else { throw NotArrived(description: "等不到：\(what)") }
        await Task.yield()
    }
}

struct NotArrived: Error, CustomStringConvertible {
    let description: String
}

extension ManualTiming {
    /// 等钟上有人睡下（指定截止时刻的，等那个时刻）：推进钟之前先确认被测的计时器已经登记。
    func sleeper(until deadline: Date? = nil) async throws {
        try await eventually("手动钟上出现睡眠者") { deadline.map { self.hasSleeper(until: $0) } ?? (self.sleeperCount > 0) }
    }
}
