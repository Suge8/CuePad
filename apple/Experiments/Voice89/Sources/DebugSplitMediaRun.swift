#if DEBUG && os(iOS)
import Network

/// 只负责串行创建/销毁每轮的 owner；转发不跨 await 持有可变的 current。
final class DebugSplitMediaRun {
    private var current: DebugSplitMedia?

    static func run() async throws { try await DebugSplitMediaRun().run() }

    private func run() async throws {
        let pipe = DebugSplitVoice.Pipe(NWConnection(host: "127.0.0.1", port: DebugSplitVoice.port, using: .tcp))
        pipe.start()
        let reader = Task {
            do { for try await frame in pipe.frames.stream { current?.receive(frame) } }
            catch { DebugSplitVoice.note("signal-read-failed") }
            current?.cancel()
        }
        defer { reader.cancel(); pipe.close() }
        for cycle in 0..<2 {
            let media = DebugSplitMedia()
            current = media
            do { try await media.run(pipe: pipe, cycle: cycle) }
            catch { current = nil; throw error }
            current = nil
        }
    }
}
#endif
