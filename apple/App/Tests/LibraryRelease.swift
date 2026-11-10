import CueStore
import Foundation
import Synchronization
import Testing

/// 用例结束前等它建过的资料库都释放：没释放的就是有任务、订阅或对象还攥着它（同一个测试宿主里只增不减，每个库占一组系统通知登记，
/// 攒到几百个宿主就崩在建库上）。检查放在用例的作用域里而不在 `TestApp` 的 deinit 里：释放要等被取消的任务收尾，deinit 等不了，
/// 用例结束后再记的问题测试框架不算到任何用例头上。`TestApp` 只在这个作用域里建（建在外面当场报错）。Swift Testing 没有进程级的作用域，只能逐个套件挂：App 的测试套件都挂（`lint_suites.py` 查）。
nonisolated struct ReleasesLibraries: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void) async throws {
        let ledger = LibraryLedger()
        let held = test.traits.lazy.compactMap { $0 as? LibraryHeldByFramework }.first
        do {
            try await LibraryLedger.$current.withValue(ledger) { try await function() }
        } catch {
            await ledger.expectReleased(knownHeld: held)
            throw error
        }
        await ledger.expectReleased(knownHeld: held)
    }
}

/// 框架自己攥着环境里的对象、测试里拆不掉时，库在收尾时还没放：只逐条用例写明是哪个框架、怎么攥的，没释放记成已知问题，
/// 哪天放掉了，测试框架报"已知问题没出现"，提醒删掉它。已知两种：SwiftUI 的视图图数据在窗口关上、视图拆掉后仍留着最后一版环境
/// （试过清空 contentView、换成空根视图并当场排版绘制、另起一次刷新，都不放）；AppKit 的文本视图进窗口时排一个延迟约半秒的
/// 主队列合并块（`NSCreateMainQueueHysteresisBlock`，更新拖放类型登记），块里攥着文本视图，到点才放，取消不了。
nonisolated struct LibraryHeldByFramework: TestTrait {
    let comment: Comment

    init(_ comment: Comment) { self.comment = comment }
}

extension Trait where Self == ReleasesLibraries {
    static var releasesLibraries: Self { Self() }
}

extension Trait where Self == LibraryHeldByFramework {
    static func libraryHeldByFramework(_ comment: Comment) -> Self { Self(comment) }
}

nonisolated final class LibraryLedger: Sendable {
    @TaskLocal static var current: LibraryLedger?

    private struct Entry {
        weak var store: CueStore?
        let createdAt: SourceLocation
    }

    private struct State {
        var stores: [Entry] = []
        var apps: [SourceLocation] = []
        var closings: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// 建 `TestApp` 时调：在 `.releasesLibraries` 的作用域外建的当场报错。
    static func opening(createdAt location: SourceLocation) -> LibraryLedger? {
        guard let ledger = current else {
            Issue.record("TestApp 要在挂了 .releasesLibraries 的套件里建：不然它的资料库有没有释放没人查", sourceLocation: location)
            return nil
        }
        ledger.state.withLock { $0.apps.append(location) }
        return ledger
    }

    func track(_ store: CueStore, createdAt location: SourceLocation) {
        state.withLock { $0.stores.append(Entry(store: store, createdAt: location)) }
    }

    /// `TestApp` 的收尾（deinit、relaunch 换下的旧实例）：当场开始，用例结束时等它做完。`app` 是 deinit 时给的，记下这个实例收尾了。
    static func close(_ ledger: LibraryLedger?, app: SourceLocation? = nil, _ work: @escaping @Sendable () async -> Void) {
        let closing = Task.detached { await work() }
        ledger?.state.withLock { state in
            state.closings.append(closing)
            if let app, let index = state.apps.firstIndex(of: app) { state.apps.remove(at: index) }
        }
    }

    private var held: [SourceLocation] { state.withLock { $0.stores.filter { $0.store != nil }.map(\.createdAt) } }

    func expectReleased(knownHeld: LibraryHeldByFramework?) async {
        // 用例在别的线程上放掉的 TestApp，deinit 排在主线程上（isolated deinit）：先让它们跑完
        await MainActor.run {}
        let (apps, closings) = state.withLock { ($0.apps, $0.closings) }
        for location in apps {
            Issue.record("这条用例的 TestApp 本身没释放：用例里还有任务或对象攥着它", sourceLocation: location)
        }
        for closing in closings { await closing.value }
        if let knownHeld {
            withKnownIssue(knownHeld.comment) { recordHeld() }
            return
        }
        // 订阅的重读任务在读的一方停下后才收尾，用例与服务都等不到它：这里等完，再让它放掉的主线程对象释放
        for store in stores { await store.stoppedSubscriptions() }
        await MainActor.run {}
        recordHeld()
    }

    private var stores: [CueStore] { state.withLock { $0.stores.compactMap(\.store) } }

    private func recordHeld() {
        for location in held {
            Issue.record("这条用例的资料库收尾后没释放：还有任务、订阅或对象攥着它（在这里建的 TestApp）", sourceLocation: location)
        }
    }
}
