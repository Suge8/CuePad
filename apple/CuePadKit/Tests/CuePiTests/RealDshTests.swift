#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 dsh（`dsh --profile acp` 叠上随包插件），录制时连真的 DeepSeek（key 只经环境给，见 `RealAgents`）。
/// 托管会话的开工、说话、歇下在 `RealCueStartTests`，这里是 dsh 才有的。
@MainActor
@Suite(RealAgents.taped(.dsh), .agentTape(.dsh), RealAgents.timeLimit(.minutes(3)), RealAgents.serialWhenRecording(.dsh))
struct RealDshTests {
    /// dsh 问你（`ask_user_question`，一次两问）：会话停在"等你回答"，逐问带着选项、也能自己填；在 CuePad 里答完第一问才出第二问，
    /// 两问都答了它拿着答案接着说，这一轮做完。
    @Test func aQuestionIsAnsweredFromCuePadOneByOne() async throws {
        try await withDshRig { rig in
            let id = try await rig.runtime.open(in: rig.work, launchToken: "token-ask", name: nil, model: rig.model, thinking: nil)
            try await rig.bridge.send(PiMessage(text: """
                Call the ask_user_question tool exactly once with two questions: id "drink", question "Which drink?", options "Tea" and "Coffee"; \
                id "size", question "Which size?", options "Small" and "Large". Then reply with exactly: drink=<answer> size=<answer>
                """), to: id)

            try await eventually("问第一问") { rig.bridge.session(id: id)?.question?.text.contains("Which drink?") == true }
            let drink = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(drink.kind == .known(.select) && drink.options == ["Tea", "Coffee"] && drink.allowsOther)
            await #expect(throws: PiBridgeError.rejected("bad_answer")) { try await rig.bridge.answer(.option("Milk"), to: try #require(drink.promptID), in: id) }
            try await rig.bridge.answer(.option("Coffee"), to: try #require(drink.promptID), in: id)

            let size = try #require(rig.bridge.session(id: id)?.question)
            #expect(size.text.contains("Which size?") && size.options == ["Small", "Large"] && size.promptID != drink.promptID)
            try await rig.bridge.answer(.text("Medium"), to: try #require(size.promptID), in: id)

            try await eventually("拿到答案接着说，这一轮做完") {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last?.contains("drink=Coffee") == true } == true
            }
            let reply = try #require(rig.bridge.session(id: id).flatMap { rig.replies($0).last })
            #expect(reply.contains("size=Medium"), "\(reply)")
            #expect(rig.bridge.session(id: id)?.question == nil)
        }
    }
}

/// 一个临时的 dsh 家目录（登录只经环境里的 DEEPSEEK_API_KEY）与工作目录，不读写真实的 ~/.dsh 与资料库；会话存进它下面 CuePad 的明文根。
@MainActor
final class DshRig {
    let root: URL
    let bridge: PiBridge
    let runtime: DshRuntime
    let model = PiModelKey(provider: "deepseek-official", id: "deepseek-flash")
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }

    init() throws {
        root = try makeTempDirectory().resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
        bridge = PiBridge(socketDirectory: root.appending(path: "s", directoryHint: .isDirectory))
        let paths = AgentPaths(environment: ["DSH_HOME": root.appending(path: "dsh").path])
        runtime = DshRuntime(bridge: bridge, paths: paths, dsh: { AgentTape.executable("dsh") }, locate: { AgentTape.locator("dsh") })
        AgentTape.current?.watch(root.appending(path: "dsh/\(DshRuntime.sessions)"))
        try bridge.start()
    }

    func stop() async {
        await runtime.stop()()
        bridge.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func replies(_ session: PiSession) -> [String] {
        let file = session.sessionFile
        let messages = file.flatMap { try? PiHistory.index(file: $0, agent: .dsh, from: nil, files: scratchFiles).messages } ?? []
        return messages.filter { $0.role == .known(.pi) }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

@MainActor
func withDshRig(_ body: (DshRig) async throws -> Void) async throws {
    let rig = try DshRig()
    do { try await body(rig) } catch { await rig.stop(); throw error }
    await rig.stop()
}
#endif
