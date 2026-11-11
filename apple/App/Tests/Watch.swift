import CueTestSupport
import Foundation

/// 等一条流接连的几项，每项都带上限（`bounded`）。先创建它（订阅）再触发被测操作；`keep` 之外的项被跳过，流结束给 nil。
nonisolated final class Watch<Element: Sendable>: @unchecked Sendable {  // 同一时刻只有一次 next 在拉，迭代器不并发
    nonisolated(unsafe) private var iterator: AsyncStream<Element>.Iterator
    private let keep: @Sendable (Element) -> Bool

    init(_ stream: AsyncStream<Element>, where keep: @escaping @Sendable (Element) -> Bool = { _ in true }) {
        iterator = stream.makeAsyncIterator()
        self.keep = keep
    }

    func next(_ what: String) async throws -> Element? {
        try await bounded(what) { await self.pull() }
    }

    private func pull() async -> Element? {
        while let value = await iterator.next() { if keep(value) { return value } }
        return nil
    }
}

/// 只等一项的：任何异步序列里第一个满足 `match` 的，带上限；序列先结束也抛。先建好序列（订阅）、再触发。
@discardableResult
func awaitNext<S: AsyncSequence & Sendable>(
    _ what: String, from stream: S, where match: @escaping @Sendable (S.Element) -> Bool = { _ in true }
) async throws -> S.Element where S.Element: Sendable {
    try await bounded(what) {
        for try await value in stream where match(value) { return value }
        throw TimedOut(description: "流结束了，没等到：\(what)")
    }
}
