import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 界面订阅的读取一律可比较：写入读到同一张表、结果没变时，不再把一份相同的数据送到主线程。
@MainActor
struct ObservedValueTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test(.timeLimit(.minutes(1))) func 回收站读取_不相干的写入重读但不再送一份相同的数据() async throws {
        let reads = Mutex(0), deliveries = Mutex(0)
        let following = Task {
            for try await _ in store.observe({ store -> TrashSummary in
                reads.withLock { $0 += 1 }
                return try TrashSummary.read(from: store)
            }) { deliveries.withLock { $0 += 1 } }
        }
        defer { following.cancel() }
        await eventually { reads.withLock { $0 } >= 1 && deliveries.withLock { $0 } == 1 }

        for index in 0..<5 { _ = try await store.createCard(in: nil, body: "不相干 \(index)") }
        await eventually { reads.withLock { $0 } >= 6 }  // 每次写入都重读了一次（读到 cards 表）
        #expect(deliveries.withLock { $0 } == 1)

        let doomed = try await store.createCard(in: nil, body: "要删的")
        try await store.trashCard(doomed.id)
        await eventually { deliveries.withLock { $0 } == 2 }  // 回收站真的变了才送
        #expect(deliveries.withLock { $0 } == 2)
    }
}
