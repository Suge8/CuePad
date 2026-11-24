import CueStore
import Foundation
import Synchronization
import Testing

/// 用例结束前等它建过的资料库都释放：没释放的就是有任务、订阅或对象还攥着它（同一个测试宿主里只增不减，每个库占一组系统通知登记，
/// 攒到几百个宿主就崩在建库上）。等完收尾后还活着的一直等到这条用例的时限（`conditionBudget`，从用例开始算）才算泄漏：
/// 收尾时还在跑的一次性任务（上传、起名、立即同步的那一拉、读的一方停了还要走几步的订阅重读）做完就放，负载高时它们走得慢，不能按墙钟定宽限；
/// 正常用例到这里已经放了、不多花时间，只有真泄漏的用例等满。检查放在用例的作用域里而不在 `TestApp` 的 deinit 里：释放要等被取消的任务收尾，deinit 等不了，
/// 用例结束后再记的问题测试框架不算到任何用例头上。`TestApp` 只在这个作用域里建（建在外面当场报错）。Swift Testing 没有进程级的作用域，只能逐个套件挂。
nonisolated struct ReleasesLibraries: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void) async throws {
        let ledger = LibraryLedger(), deadline = ContinuousClock.now + conditionBudget
        do {
            try await LibraryLedger.$current.withValue(ledger) { try await function() }
        } catch {
            await ledger.expectReleased(by: deadline)
            throw error
        }
        await ledger.expectReleased(by: deadline)
    }
}

extension Trait where Self == ReleasesLibraries {
    static var releasesLibraries: Self { Self() }
}

nonisolated final class LibraryLedger: Sendable {
    @TaskLocal static var current: LibraryLedger?

    private struct Entry {
        weak var store: CueStore?
        let createdAt: SourceLocation
    }

    private struct Excused {
        weak var store: CueStore?
        let comment: Comment
        let intermittent: Bool
    }

    private struct State {
        var stores: [Entry] = []
        var apps: [SourceLocation] = []
        var closings: [Task<Void, any Error>] = []
        var excused: Excused?
    }

    private let state = Mutex(State())

    static func opening(createdAt location: SourceLocation) -> LibraryLedger? {
        guard let ledger = current else {
            Issue.record("TestApp 要在挂了 .releasesLibraries 的套件里建：不然它的资料库有没有释放没人查", sourceLocation: location)
            return nil
        }
        ledger.state.withLock { $0.apps.append(location) }
        return ledger
    }

    static func tracking(_ store: CueStore, createdAt location: SourceLocation) {
        guard let ledger = current else {
            Issue.record("建服务要在挂了 .releasesLibraries 的套件里：不然它的资料库有没有释放没人查", sourceLocation: location)
            return
        }
        ledger.track(store, createdAt: location)
    }

    /// 框架自己攥着环境里的对象、测试里拆不掉时调，指认它攥着的那一个库：收尾时按对象身份只豁免它，没释放记成已知问题，
    /// 同一用例里别的没放的照报泄漏；它放掉了，测试框架报"已知问题没出现"，提醒删掉这一行。先用 `leaks --traceTree <对象地址> <pid>` 查清引用链再指认：
    /// 曾以为 Mac 上 SwiftUI 视图图留着环境，实为文件草稿与工作区互相攥着。已知一种（iOS）：UIKit 攥着最后一个拿过键盘的文本视图，
    /// 键盘单例的标记文字浮层（`UIKeyboardImpl.m_markedTextOverlay`）缓存的特征集合带着 SwiftUI 环境（交出键盘、结束编辑、关窗、清根视图都不放）。
    /// AppKit 文本视图进窗口时排的延迟合并块（`NSCreateMainQueueHysteresisBlock`）攥着它约半秒，收尾时等得到它放掉，不算。
    /// `intermittent`：只在某些环境里放不掉（Mac 文件页那条：本机放掉、CI 的 runner 上不放），放掉了不报"已知问题没出现"。
    static func heldByFramework(_ store: CueStore, _ comment: Comment, intermittent: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let ledger = current else {
            Issue.record("指认框架攥着的库要在挂了 .releasesLibraries 的套件里", sourceLocation: sourceLocation)
            return
        }
        ledger.state.withLock { $0.excused = Excused(store: store, comment: comment, intermittent: intermittent) }
    }

    func track(_ store: CueStore, createdAt location: SourceLocation) {
        state.withLock { $0.stores.append(Entry(store: store, createdAt: location)) }
    }

    static func close(_ ledger: LibraryLedger?, app: SourceLocation? = nil, _ work: @escaping @Sendable () async throws -> Void) {
        let closing = Task.detached { try await work() }
        ledger?.state.withLock { state in
            state.closings.append(closing)
            if let app, let index = state.apps.firstIndex(of: app) { state.apps.remove(at: index) }
        }
    }

    private var waiting: Bool { state.withLock { state in state.stores.contains { $0.store != nil && $0.store !== state.excused?.store } } }

    func expectReleased(by deadline: ContinuousClock.Instant) async {
        await MainActor.run {}
        let (apps, closings) = state.withLock { ($0.apps, $0.closings) }
        for location in apps {
            Issue.record("这条用例的 TestApp 本身没释放：用例里还有任务或对象攥着它", sourceLocation: location)
        }
        for closing in closings {
            do { try await closing.value } catch { Issue.record("旧实例没停干净：\(error)") }
        }
        while waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let (live, excused) = state.withLock { state in
            (state.stores.compactMap { entry in entry.store.map { ($0, entry.createdAt) } }, state.excused)
        }
        if let excused {
            // 指认的那个放掉了也进来一次：里面不记问题，测试框架就报"已知问题没出现"
            withKnownIssue(excused.comment, isIntermittent: excused.intermittent) {
                for (store, location) in live where store === excused.store { record(location) }
            }
        }
        for (store, location) in live where store !== excused?.store { record(location) }
    }

    private func record(_ location: SourceLocation) {
        Issue.record("这条用例的资料库收尾后没释放：还有任务、订阅或对象攥着它（在这里建的 TestApp）", sourceLocation: location)
    }
}
