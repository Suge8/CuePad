import Foundation

/// 等一条流的下一项，带上限：等不到抛出，写明在等什么（裸 `for await` / `iterator.next()` 等不到只会挂到整个测试超时）。
/// 先创建它（订阅）再触发被测操作；`keep` 之外的项被跳过。
nonisolated final class Watch<Element: Sendable>: @unchecked Sendable {  // 同一时刻只有一次 next 在拉，迭代器不并发
    struct TimedOut: Error, CustomStringConvertible { let description: String }

    nonisolated(unsafe) private var iterator: AsyncStream<Element>.Iterator
    private let keep: @Sendable (Element) -> Bool

    init(_ stream: AsyncStream<Element>, where keep: @escaping @Sendable (Element) -> Bool = { _ in true }) {
        iterator = stream.makeAsyncIterator()
        self.keep = keep
    }

    func next(_ what: String) async throws -> Element? {
        try await withThrowingTaskGroup(of: Element?.self) { group in
            group.addTask { await self.pull() }
            group.addTask {
                try await Task.sleep(for: conditionBudget)
                throw TimedOut(description: "等不到：\(what)")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func pull() async -> Element? {
        while let value = await iterator.next() { if keep(value) { return value } }
        return nil
    }
}
