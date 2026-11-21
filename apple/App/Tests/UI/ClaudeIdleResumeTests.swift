#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge

@Suite(.releasesLibraries, .enabled(if: PinnedAgent.claude.uncovered == nil, Comment(rawValue: PinnedAgent.claude.uncovered ?? "")), .timeLimit(.minutes(4)))
@MainActor
struct ClaudeIdleResumeTests {
    @Test func 托管会话请退出还没走时本机发话_接着它得到回复_旧进程收掉() async throws {
        try await ClaudeRig.run(wrapper: Self.wrapper, hostedIdle: .seconds(3)) { rig in try await idleThenSay(rig) }
    }

    private static let wrapper = #"[ "$1" = --input-format ] || exec "$REAL" "$@"; dir=${0%/*}; echo $$ >> "$dir/pids"; "#
        + #""$REAL" "$@"; : > "$dir/eof.$$"; while :; do sleep 1; done"#

    private func idleThenSay(_ rig: ClaudeRig) async throws {
        let id = try await rig.runtime.open(in: rig.work, launchToken: "hosted", name: nil, model: nil, thinking: nil)
        let session = try #require(rig.bridge.session(id: id))
        let sessionID = session.sessionID
        try await rig.bridge.send(SessionMessage(text: "开场"), to: id)
        // 第一句话前 Claude Code 自己加了一段 system-reminder，假模型照样回声
        try await eventually("回答落盘、索引跟上") { try await rig.replies(of: sessionID).last?.hasSuffix("开场") == true }

        try await eventually("空闲到点，请它退出了") { FileManager.default.fileExists(atPath: rig.bin.appending(path: "eof.\(session.pid)").path) }
        #expect(rig.bridge.session(sessionID: sessionID) == nil, "请它退出了还在桥上")
        await Workspace(services: rig.services).send("闲置后的话", to: AgentTarget(session: sessionID)).value
        let request = try #require(try await rig.store.deliveryRequests(toSession: sessionID).last)
        let result = try await rig.store.outcome(of: request)

        #expect(result.status == .known(.succeeded), "\(result.reason.map(String.init(describing:)) ?? "")")
        try await eventually("闲置后的话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 闲置后的话" }
        #expect(kill(session.pid, 0) != 0, "旧进程还在")
        #expect(rig.bridge.session(sessionID: sessionID).map { $0.pid != session.pid } == true, "接着它的是新进程")
    }
}
#endif
