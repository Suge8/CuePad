import Foundation
import Testing
@testable import CuePad

/// 自动保存：停手后写入的那次保存要在正常（未取消）的任务里跑，否则写库和保存后的状态提示都会被提前打断。
@MainActor
struct AutosaveTests {
    @Test func 停手后的自动保存不在已取消的任务里执行() async {
        let (saves, sink) = AsyncStream.makeStream(of: Bool.self)
        let autosave = Autosave(save: { _ in sink.yield(Task.isCancelled) }, onError: { _ in })

        autosave.changed("正文")
        var iterator = saves.makeAsyncIterator()
        let cancelled = await iterator.next()

        withExtendedLifetime(autosave) {}
        #expect(cancelled == false)
    }
}
