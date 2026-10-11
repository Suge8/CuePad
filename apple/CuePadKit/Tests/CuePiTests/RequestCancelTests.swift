#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 取消一条等 ack 的命令：立即以取消结束，不用等 ack 超时（10 秒）。
@MainActor
struct RequestCancelTests {
    @Test func cancellingACommandWaitingForItsAckReturnsAtOnce() async throws {
        let dir = try makeSocketDirectory()
        let bridge = PiBridge(socketDirectory: dir)
        let ext = FakeExtension(directory: dir)
        ext.onCommand = { _, _ in nil }  // 扩展收到命令不回 ack
        try ext.start()
        try bridge.start()
        await eventually("会话出现") { bridge.session(id: ext.id) != nil }

        let request = Task { try await bridge.abort(ext.id) }
        await eventually("命令已发出") { !ext.commands.isEmpty }
        request.cancel()

        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
#endif
