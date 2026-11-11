#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge

/// 托管的真 Claude Code（钉住的版本，`ClaudeSandbox` 隔离、假模型回 `ECHO <你的话>`）歇满空闲时限被请退出、进程还没走的那段里，
/// 从 Mac 本机发话：投送接着这个会话、得到回复，旧进程收掉（不是报"会话已经结束"）。
/// 外壳（`wrapper`）起的托管进程在 Claude Code 读到 EOF 退出后（`eof.<pid>`：CuePad 已请它退出；pid 是外壳的，也是桥上记的）
/// 一直握着输出、不自己走：只有 CuePad 收它才会结束。只看这个会话的：App 起来时问登录与模型清单也起一个、问完就关（`AgentFacts.probe`）。
@Suite(.releasesLibraries, .enabled(if: PinnedAgent.claude.uncovered == nil, Comment(rawValue: PinnedAgent.claude.uncovered ?? "")), .timeLimit(.minutes(4)))
@MainActor
struct ClaudeIdleResumeTests {
    @Test func 托管会话请退出还没走时本机发话_接着它得到回复_旧进程收掉() async throws {
        try await ClaudeRig.run(wrapper: Self.wrapper, hostedIdle: .seconds(3)) { rig in try await idleThenSay(rig) }
    }

    /// 只拦托管进程（`ClaudeStream` 带 `--input-format`），问版本、列会话的原样交给真的；每起一个记下 pid（`ClaudeRig.shutdown` 按它收）
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
