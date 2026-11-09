#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

/// 摘要请求的停住与成败由对话里的标记控制（`[[slow-compact]]`、`[[fail-compact]]`、`[[overflow]]`，见 Fixtures/fake-model.ts）：
/// 压缩停住多久由测试决定（`PiProcess.release`），不按时长——机器负载高时测试自己的步骤会慢过任何固定窗口。
@MainActor
@Suite(RealAgents.taped(.pi), .agentTape(.pi), RealAgents.serialWhenRecording(.pi), RealAgents.timeLimit(.minutes(5)))
struct RealCompactTests {
    /// `keepRecentTokens` 很小：两轮对话就有可压缩的；`reserveTokens` 决定自动压缩的阈值（窗口 10 万减去它）。
    private func withRig(reserveTokens: Int = 16_384, _ body: (PiProcess, PiBridge, PiSession) async throws -> Void) async throws {
        let pi = try await PiProcess(settings: ["compaction": ["keepRecentTokens": 10, "reserveTokens": reserveTokens]])
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        try await body(pi, bridge, bridge.sessions[0])
    }

    private func compactions(in session: PiSession) throws -> Int {
        try PiHistory.index(file: #require(session.sessionFile), from: nil).messages.filter { $0.role == .known(.system) }.count
    }

    private func releaseWhileCompacting(_ pi: PiProcess, _ bridge: PiBridge) -> Task<Void, any Error> {
        Task { @MainActor in
            while true {
                try await pi.waitUntilHeld()
                try await eventually("在压缩") { bridge.sessions.first?.state == .compacting }
                try pi.release()
            }
        }
    }

    private func reply(_ pi: PiProcess, _ bridge: PiBridge, _ text: String) async throws {
        let before = bridge.sessions.first?.stateSince
        try pi.prompt(text)
        try await eventually("这一轮做完") {
            bridge.sessions.first.map { $0.state == .settled && $0.stateSince != before } == true
        }
    }

    @Test func 手动压缩期间说话_停下压缩_以这句开新一轮() async throws {
        try await withRig { pi, bridge, s in
            try await reply(pi, bridge, "第一轮 [[slow-compact]]")
            try await reply(pi, bridge, "第二轮")
            let settled = try #require(bridge.sessions.first)
            let log = ChangeLog(bridge)

            let compact = Task { try await bridge.command("/compact", in: s.id) }  // 压完才确认
            try await eventually("在压缩") { bridge.sessions.first?.state == .compacting }
            let compacting = try #require(bridge.sessions.first)
            #expect(compacting.busySince != nil && compacting.stateSince > settled.stateSince)
            try await bridge.send(PiMessage(text: "压缩时说的话"), to: s.id)

            try await eventually("这句开的一轮答完") {
                (try? PiHistory.index(file: #require(s.sessionFile), from: nil).checkpoint.recap.lastReply) == "ECHO 压缩时说的话 IMAGES[]"
            }
            try await eventually("那一轮的状态都到了桥上") { log.states.last == .settled && log.states.count >= 4 }
            #expect(try compactions(in: s) == 0, "压缩被停下")
            let states = log.states
            let back = try #require(states.firstIndex(of: .compacting).map { states[($0 + 1)...] }?.first)
            #expect(back == .settled, "先回到压缩前的歇下，再开始那句话的一轮")
            let resumed = try #require(log.changes.compactMap { change -> PiSession? in
                if case .stateChanged(let session, .compacting) = change { session } else { nil }
            }.first)
            #expect(resumed.stateSince == settled.stateSince && resumed.busySince == nil)
            await #expect(throws: PiBridgeError.rejected("failed: Compaction cancelled")) { try await compact.value }
        }
    }

    @Test func 手动压缩被停止回到原来的状态与计时_失败报错() async throws {
        try await withRig { pi, bridge, s in
            try await reply(pi, bridge, "第一轮 [[slow-compact]] [[fail-compact]]")
            try await reply(pi, bridge, "第二轮")
            let settled = try #require(bridge.sessions.first)
            let log = ChangeLog(bridge)

            let stopping = Task { try await bridge.command("/compact", in: s.id) }  // 压完才确认
            try await eventually("在压缩") { bridge.sessions.first?.state == .compacting }
            try await bridge.abort(s.id)
            await #expect(throws: PiBridgeError.rejected("failed: Compaction cancelled")) { try await stopping.value }
            try await eventually("停下后回落") { log.states == [.compacting, .settled] }
            #expect(bridge.sessions.first?.stateSince == settled.stateSince && bridge.sessions.first?.busySince == nil)

            let releasing = releaseWhileCompacting(pi, bridge)
            defer { releasing.cancel() }
            await #expect(throws: PiBridgeError.self, "压缩失败，命令以失败回") { try await bridge.command("/compact", in: s.id) }
            try await eventually("失败报成出错") { log.states.count == 4 && log.states.last == .error }
            #expect(bridge.sessions.first?.errorMessage?.contains("fake model failure") == true)
            #expect(try compactions(in: s) == 0)
        }
    }

    @Test func 上下文快满时自动压缩_是这一轮里的一档工作中() async throws {
        try await withRig(reserveTokens: 99_000) { pi, bridge, s in
            try await reply(pi, bridge, "热身 [[slow-compact]]")
            let log = ChangeLog(bridge)
            let releasing = releaseWhileCompacting(pi, bridge)
            defer { releasing.cancel() }
            try await reply(pi, bridge, String(repeating: "上下文填充 ", count: 1_000))

            try await eventually("日志记下了") { log.states.last == .settled }
            #expect(log.states.contains(.compacting))
            let working = log.changes.compactMap { change -> PiSession? in
                if case .stateChanged(let session, _) = change, session.state != .settled { session } else { nil }
            }
            #expect(Set(working.map(\.stateSince)).count == 1, "思考、工具、压缩是同一段工作")
            #expect(try compactions(in: s) == 1)
        }
    }

    @Test func 上下文溢出后压缩再重试_报在压缩_重试成功正常做完() async throws {
        try await withRig { pi, bridge, s in
            try await reply(pi, bridge, "热身 [[slow-compact]]")
            let log = ChangeLog(bridge)
            let releasing = releaseWhileCompacting(pi, bridge)
            defer { releasing.cancel() }
            try await reply(pi, bridge, "[[overflow]] 再说一遍")

            try await eventually("日志记下了") { log.states.last == .settled }
            #expect(log.states.contains(.compacting))
            #expect(!log.states.contains { if case .error = $0 { true } else { false } })
            #expect(try compactions(in: s) == 1)
        }
    }
}
#endif
