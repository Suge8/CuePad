import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 界面订阅的读取一律可比较：写入读到同一张表、结果没变时，不再把一份相同的数据送到主线程。
struct ObservedValueTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    /// 只数送达的份数，不管中间重读了几次（突发的写入允许合并成一次重读）。回收站真的变了的那一份排在所有无关写入之后，
    /// 它是第二份，说明在它之前没有多送过相同的数据。
    @Test(.timeLimit(.minutes(1))) func 回收站读取_不相干的写入不再送一份相同的数据() async throws {
        let deliveries = Mutex(0)
        let following = Task {
            for try await _ in store.observe({ try TrashSummary.read(from: $0) }) { deliveries.withLock { $0 += 1 } }
        }
        defer { following.cancel() }
        try await eventually("deliveries.withLock { $0 } == 1") { deliveries.withLock { $0 } == 1 }

        for index in 0..<5 { _ = try await store.createCard(in: nil, body: "不相干 \(index)") }
        let doomed = try await store.createCard(in: nil, body: "要删的")
        try await store.trashCard(doomed.id)
        try await eventually("deliveries.withLock { $0 } >= 2") { deliveries.withLock { $0 } >= 2 }

        #expect(deliveries.withLock { $0 } == 2)
    }
}
