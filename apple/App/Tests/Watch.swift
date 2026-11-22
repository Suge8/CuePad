import CueTestSupport
import Foundation

nonisolated final class Watch<Element: Sendable>: @unchecked Sendable {
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

@discardableResult
func awaitNext<S: AsyncSequence & Sendable>(
    _ what: String, from stream: S, where match: @escaping @Sendable (S.Element) -> Bool = { _ in true }
) async throws -> S.Element where S.Element: Sendable {
    try await bounded(what) {
        for try await value in stream where match(value) { return value }
        throw TimedOut(description: "流结束了，没等到：\(what)")
    }
}
