#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

/// 压缩上下文是会话状态里的一档"工作中"（`.compacting`）：真实 Pi + 安装器装进临时目录的真实扩展 + 假模型 + `PiBridge`。
/// 手动 /compact、上下文快满时自动压缩、上下文溢出后压缩再重试，三种都先报"在压缩"；
/// 歇着时开始的压缩（手动）结束、失败或被停止后回到原来的状态和原来的计时起点——不是新的一轮。
/// 摘要请求的停住与成败由对话里的标记控制（`[[slow-compact]]`、`[[fail-compact]]`、`[[overflow]]`，见 Fixtures/fake-model.ts）：
/// 压缩停住多久由测试决定（`PiProcess.release`），不按时长——机器负载高时测试自己的步骤会慢过任何固定窗口。
@MainActor
@Suite(.enabled(if: realPiAvailable, "需要 ~/.local/bin/pi"))
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

    /// 摘要请求每次停住，都等桥上看到"在压缩"再放行（压缩会发一到两次摘要请求）；不再需要时取消。
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

    @Test func 手动压缩先报在压缩_做完回到原来的状态与计时_期间说的话压完再送进去() async throws {
        try await withRig { pi, bridge, s in
            try await reply(pi, bridge, "第一轮 [[slow-compact]]")
            try await reply(pi, bridge, "第二轮")
            let settled = try #require(bridge.sessions.first)
            let log = ChangeLog(bridge)

            try await bridge.command("/compact", in: s.id)
            try await eventually("在压缩") { bridge.sessions.first?.state == .compacting }
            let compacting = try #require(bridge.sessions.first)
            #expect(compacting.busySince != nil && compacting.stateSince > settled.stateSince)
            try await bridge.send(PiMessage(text: "压缩时说的话"), to: s.id)
            let releasing = releaseWhileCompacting(pi, bridge)
            defer { releasing.cancel() }

            try await eventually("压完") { try self.compactions(in: s) == 1 }
            try await eventually("压完的话送进去、答完") {
                (try? PiHistory.index(file: #require(s.sessionFile), from: nil).checkpoint.recap.lastReply) == "ECHO 压缩时说的话 IMAGES[]"
            }
            try await eventually("那一轮的状态都到了桥上") { log.states.last == .settled && log.states.count >= 4 }
            let states = log.states
            let back = try #require(states.firstIndex(of: .compacting).map { states[($0 + 1)...] }?.first)
            #expect(back == .settled, "压完先回到原来的歇下，再开始那句话的一轮")
            let resumed = try #require(log.changes.compactMap { change -> PiSession? in
                if case .stateChanged(let session, .compacting) = change { session } else { nil }
            }.first)
            #expect(resumed.stateSince == settled.stateSince && resumed.busySince == nil)
        }
    }

    /// 压缩期间留着的话，会话在压完前退出或重新载入：告别时报出这些话没送到（投送请求 id），不悄悄丢掉；
    /// 交给 Pi 派发的斜杠命令在手动压缩期间直接拒收（没有投送请求 id，留着就没法报）。
    @Test(arguments: ["quit", "reload"])
    func 压缩期间留着的话_会话压完前关掉_告别时报没送到(how: String) async throws {
        try await withRig { pi, bridge, s in
            try await reply(pi, bridge, "第一轮 [[slow-compact]]")
            try await reply(pi, bridge, "第二轮")
            let log = ChangeLog(bridge)

            try await bridge.command("/compact", in: s.id)
            try await eventually("在压缩") { bridge.sessions.first?.state == .compacting }
            let delivery = UUID().uuidString
            try await bridge.send(PiMessage(text: "压缩时说的话", deliveryID: delivery), to: s.id)
            await #expect(throws: PiBridgeError.rejected("compacting")) { try await bridge.command("/ask", in: s.id) }
            if how == "quit" { pi.kill(SIGTERM) } else { try await bridge.command("/reload", in: s.id) }

            try await eventually("会话告别") { !log.ended.isEmpty }
            try await eventually("日志记下了") { log.ended.first?.1 == .closed(reason: how, undelivered: [delivery]) }
        }
    }

    @Test func 手动压缩失败或被停止_回到原来的状态与计时() async throws {
        try await withRig { pi, bridge, s in
            // 摘要请求先停住再失败：失败在受理之后，命令照常受理
            try await reply(pi, bridge, "第一轮 [[slow-compact]] [[fail-compact]]")
            try await reply(pi, bridge, "第二轮")
            let settled = try #require(bridge.sessions.first)
            let log = ChangeLog(bridge)

            try await bridge.command("/compact", in: s.id)
            let releasing = releaseWhileCompacting(pi, bridge)  // 命令受理后才放行，失败才在受理之后
            try await eventually("失败后回落") { log.states == [.compacting, .settled] }
            releasing.cancel()
            #expect(bridge.sessions.first?.stateSince == settled.stateSince)

            try await bridge.command("/compact", in: s.id)
            try await eventually("在压缩") { bridge.sessions.first?.state == .compacting }
            try await bridge.abort(s.id)
            try await eventually("停下后回落") { log.states.count == 4 && log.states.last == .settled }
            #expect(bridge.sessions.first?.stateSince == settled.stateSince && bridge.sessions.first?.busySince == nil)
            #expect(try compactions(in: s) == 0)
        }
    }

    /// 自动压缩发生在一轮里（回答之后、彻底歇下之前）：同一段工作中的一档，计时不断；压完歇下是这一轮做完。
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
            #expect(Set(working.map(\.stateSince)).count == 1, "思考、输出、压缩是同一段工作")
            #expect(try compactions(in: s) == 1)
        }
    }

    /// 上下文溢出：模型报错后 Pi 压缩再重试这一轮，重试成功就是正常做完，不是出错。
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
