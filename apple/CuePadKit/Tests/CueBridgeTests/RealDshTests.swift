#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

/// 托管会话的开工、说话、歇下在 `RealCueStartTests`，这里是 dsh 才有的。真 dsh（钉住的版本）连本用例的假模型。
/// dsh 的 ACP 实测不发 `session/request_permission`（0.2.1-rc.5：bash 在工作目录里、write 写到工作目录外，都直接执行）；它的提问与接着会话同各家（`RealHostedTurnTests`、`RealHostedResumeTests`）。
@MainActor
@Suite(RealAgents.needs(.dsh), RealAgents.tiered, .timeLimit(.minutes(3)))
struct RealDshTests {
    /// 发送：起的是钉住版本的真 dsh，话到了模型（Messages，带着工具清单），回答回到对话里。
    @Test func aMessageReachesTheModelAndItsAnswerComesBack() async throws {
        try await withDshRig { rig in
            let id = try await rig.runtime.open(in: rig.work, launchToken: "token-send", name: nil, model: rig.model, thinking: nil)
            let command = commandLine(of: try #require(rig.bridge.session(id: id)).pid)
            #expect(command.contains("/\(PinnedAgent.dsh.name)/\(PinnedAgent.dsh.version)/"), "起的不是钉住的 dsh：\(command)")
            try await rig.bridge.send(SessionMessage(text: "Reply with exactly the word PONG."), to: id)
            try await rig.settled(id, replying: "PONG")
            let request = try #require(rig.fake.requests.first { $0.prompt.contains("PONG") }, "假模型没收到")
            #expect(request.api == .messages && request.model == rig.model.id && !request.tools.isEmpty, "\(request.api) \(request.model)")
        }
    }

    /// 停止：模型的回答停着时点停止，到模型的连接随之断开、会话歇下，再说一句照常回答。
    @Test func stoppingAHeldRoundDisconnectsTheModelAndTheNextMessageIsAnswered() async throws {
        try await withDshRig { rig in
            let gate = rig.fake.gate()
            // 停下的那句没有回答，随后的话 dsh 与它并成同一条你的话（含“Take your time”）发给模型：只停第一次
            rig.fake.on("Take your time", times: 1, .held(gate, then: .say("LATE")))
            let id = try await rig.runtime.open(in: rig.work, launchToken: "token-stop", name: nil, model: rig.model, thinking: nil)
            try await rig.bridge.send(SessionMessage(text: "Take your time"), to: id)
            try await gate.reached()
            #expect(rig.bridge.session(id: id)?.state.isWorking == true)

            try await rig.bridge.abort(id)
            try await eventually("到模型的连接断了") { gate.waiting == 0 }
            try await eventually("会话歇下") { rig.bridge.session(id: id)?.state == .settled }

            try await rig.bridge.send(SessionMessage(text: "Reply with exactly the word NEXT."), to: id)
            try await rig.settled(id, replying: "NEXT")
            #expect(rig.bridge.session(id: id).map { rig.replies($0) }?.contains { $0.contains("LATE") } == false, "停下的那一轮不该有回答")
        }
    }

}

func commandLine(of pid: Int32) -> String {
    let ps = Process()
    ps.executableURL = URL(filePath: "/bin/ps")
    ps.arguments = ["-p", String(pid), "-o", "command="]
    let output = Pipe()
    ps.standardOutput = output
    guard let exit = try? ProcessExit(launching: ps) else { return "" }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    _ = exit.blockingValue
    return text
}

/// 一个临时的 dsh 家目录与工作目录，不读写真实的 ~/.dsh 与资料库；会话存进它下面 CuePad 的明文根。真 dsh 是钉住的版本，
/// 模型地址 `DEEPSEEK_BASE_URL` 与搜索地址 `DEEPSEEK_SEARCH_BASE_URL` 都指到本用例的假模型，key 是假的。
@MainActor
final class DshRig {
    let root: URL
    let bridge: Bridge
    let fake: FakeModel
    let paths: AgentPaths
    let runtime: DshRuntime
    let model = ModelKey(provider: "deepseek-official", id: "deepseek-flash")
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }

    /// dsh 的完整环境（也是大脑用的）：HOME 与 DSH_HOME 在 `root` 里，没有任何真实的密钥或登录。
    static func environment(_ fake: FakeModel, in root: URL) throws -> [String: String] {
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        return PinnedAgent.dsh.environment(home: root.appending(path: "home"), [
            "DSH_HOME": root.appending(path: "dsh").path, "DEEPSEEK_API_KEY": "fake-key", "DEEPSEEK_BASE_URL": fake.baseURL,
            "DEEPSEEK_SEARCH_BASE_URL": fake.baseURL, "DSH_TELEMETRY_DISABLED": "1",
        ])
    }

    init(fake: FakeModel? = nil) async throws {
        try PinnedAgent.dsh.require()
        root = try makeTempDirectory().resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
        let model: FakeModel
        if let fake { model = fake } else { model = try await FakeModel() }
        self.fake = model
        paths = AgentPaths(environment: try Self.environment(model, in: root))
        bridge = Bridge(socketDirectory: root.appending(path: "s", directoryHint: .isDirectory))
        runtime = DshRuntime(bridge: bridge, paths: paths, dsh: { PinnedAgent.dsh.executable }, locate: { PinnedAgent.dsh.locator }, timing: noDeadline)
        try bridge.start()
    }

    func stop() async {
        await runtime.stop()()
        bridge.stop()
        fake.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func replies(_ session: Session) -> [String] {
        let file = session.sessionFile
        let messages = file.flatMap { try? History.index(file: $0, agent: .dsh, from: nil, files: scratchFiles).messages } ?? []
        return messages.filter { $0.role == .known(.pi) }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func settled(_ id: Session.ID, replying text: String) async throws {
        try await eventually("这一轮做完，回答里有 \(text)") {
            self.bridge.session(id: id).map { $0.state == .settled && self.replies($0).last?.contains(text) == true } == true
        }
    }
}

@MainActor
func withDshRig(_ body: (DshRig) async throws -> Void) async throws {
    let rig = try await DshRig()
    do { try await body(rig) } catch { await rig.stop(); throw error }
    await rig.stop()
}
#endif
