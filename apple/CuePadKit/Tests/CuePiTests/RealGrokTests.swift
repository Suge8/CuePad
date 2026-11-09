#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 录制时连假模型，见 `GrokModel`。
@MainActor
@Suite(RealAgents.taped(.grok), .agentTape(.grok), RealAgents.timeLimit(.minutes(3)), RealAgents.serialWhenRecording(.grok))
struct RealGrokTests {
    @Test func aHostedSessionTakesAMessageWithAnImageIsConfiguredEndedAndResumed() async throws {
        try await withGrokRig { rig in
            let log = ChangeLog(rig.bridge)
            let id = try await rig.open("token-1")

            let opened = try #require(rig.bridge.session(id: id))
            #expect(opened.hosted && opened.agent == .grok && opened.launchToken == "token-1")
            let delivery = UUID()
            let message = PiMessage(text: "What color is this image? Answer with one lowercase word.", images: [PiImage(mimeType: "image/png", data: redPNG)], deliveryID: delivery.uuidString)
            try await rig.bridge.send(message, to: id)
            try await eventually("这一轮做完、报了上下文余量、回答落盘") {
                log.states.contains(.thinking) && rig.bridge.session(id: id).map {
                    $0.state == .settled && $0.context?.window ?? 0 > 0 && rig.replies($0).last?.lowercased().contains("red") == true
                } == true
            }

            let session = try #require(rig.bridge.session(id: id))
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text.hasPrefix("What color is this image?") && mine.text.contains("![](cuepad://file/"))

            let other = try #require(session.availableModels.first { $0.key.id != session.model?.key.id })
            try await rig.bridge.configure(PiConfig(model: other.key, thinking: .high, name: "看图"), in: id)
            #expect(rig.bridge.session(id: id)?.model?.key == other.key)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            let unknown = await #expect(throws: PiBridgeError.unknownModel(.grok)) {
                try await rig.bridge.configure(PiConfig(model: PiModelKey(provider: AgentKind.grok.rawValue, id: "no-such-model")), in: id)
            }
            #expect(unknown?.localizedDescription == "Grok Build 里没有这个模型")

            try await rig.bridge.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let file = try #require(session.sessionFile)
            let resumed = try await rig.runtime.resume(IndexedSession(id: session.sessionID, path: file.path, cwd: rig.work.path, lastActivityAt: .now, agent: .grok))
            #expect(rig.bridge.session(id: resumed)?.hosted == true && rig.bridge.session(id: resumed)?.sessionID == session.sessionID)
            try await rig.bridge.send(PiMessage(text: "Reply with the single word AGAIN."), to: resumed)
            try await eventually("接着回答了") { rig.replied("AGAIN", in: resumed) }
        }
    }

    /// 用例的话是真模型也照做的明确指令，断言只看你看得到的（假模型的剧本认这几句原话，`FakeResponses.plan`）。
    @Test func aPermissionRequestIsAnsweredFromCuePad() async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-2")
            let marker = rig.work.appending(path: "marker.txt")

            try await rig.bridge.send(PiMessage(text: "Use the run_terminal_command tool to run exactly: echo ok > marker.txt  Then reply with only DONE."), to: id)
            try await eventually("等你确认") { rig.bridge.session(id: id)?.question != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.confirm) && question.text.contains("echo ok > marker.txt"), "\(question.text)")

            try await rig.bridge.answer(.confirmed(true), to: try #require(question.promptID), in: id)

            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled && rig.replied("DONE", in: id) }
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func aQuestionIsAnsweredFromCuePadOneByOne() async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-ask")
            try await rig.bridge.send(PiMessage(text: """
                Use the ask_user_question tool once to ask me exactly two single-select questions: "Which drink?" with options Tea \
                (description: hot) and Coffee (description: strong), then "Which size?" with options Small (description: small cup) \
                and Large (description: large cup). Then reply with only my two answers.
                """), to: id)

            try await eventually("问第一问") { rig.bridge.session(id: id)?.question?.options.contains("Coffee") == true }
            let drink = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(drink.kind == .known(.select) && Set(drink.options) == ["Tea", "Coffee"] && drink.allowsOther && drink.text.contains("Coffee："), "\(drink)")
            await #expect(throws: PiBridgeError.rejected("bad_answer")) { try await rig.bridge.answer(.option("Milk"), to: try #require(drink.promptID), in: id) }
            try await rig.bridge.answer(.option("Coffee"), to: try #require(drink.promptID), in: id)

            let size = try #require(rig.bridge.session(id: id)?.question)
            #expect(Set(size.options) == ["Small", "Large"] && size.allowsOther && size.promptID != drink.promptID, "\(size)")
            try await rig.bridge.answer(.text("Medium"), to: try #require(size.promptID), in: id)

            try await eventually("拿到答案接着说，这一轮做完") {
                rig.bridge.session(id: id)?.state == .settled && rig.replied("Coffee", in: id) && rig.replied("Medium", in: id)
            }
            #expect(rig.bridge.session(id: id)?.question == nil)
        }
    }

    @Test func aRunningTurnIsAborted() async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-3")
            try await rig.bridge.send(PiMessage(text: "Write the numbers from 1 to 400, one per line."), to: id)
            try await eventually("在说") { rig.bridge.session(id: id)?.state == .thinking && rig.bridge.slots.first { $0.id == id }?.draft != nil }

            try await rig.bridge.abort(id)
            try await eventually("停下歇着") { rig.bridge.session(id: id)?.state == .settled }
            try await rig.bridge.send(PiMessage(text: "Reply with the single word NEXT."), to: id)
            try await eventually("接着回答了") { rig.replied("NEXT", in: id) }
        }
    }


}

/// 一个临时的 Grok 配置目录与工作目录，起的 grok 与家目录都指到这里，不读写真实的 ~/.grok 与资料库。
@MainActor
final class GrokRig {
    let root: URL
    let bridge: PiBridge
    let runtime: GrokRuntime
    var home: URL { root.appending(path: "grok", directoryHint: .isDirectory) }
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }

    init() throws {
        root = try makeTempDirectory().resolvingSymlinksInPath()
        for directory in [root.appending(path: "grok"), root.appending(path: "work"), root.appending(path: "user")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sockets = root.appending(path: "s", directoryHint: .isDirectory)
        let isolated = ["CUEPAD_", "GROK_", "XDG_", "CLAUDE_", "PI_"]
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in !isolated.contains { key.hasPrefix($0) } }.merging([
            "HOME": root.appending(path: "user").path, "GROK_HOME": root.appending(path: "grok").path, "CUEPAD_PI_SOCKET_DIR": sockets.path,
            "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path,
        ]) { $1 }
        let paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        bridge = PiBridge(socketDirectory: sockets)
        runtime = GrokRuntime(
            bridge: bridge, paths: paths, files: scratchFiles, grok: { AgentTape.executable("grok") }, locate: { AgentTape.locator("grok") }, timing: noDeadline)
        // 会话目录里 CuePad 只读会话记录（`updates.jsonl`），别的（工具定义、检索库）不录
        AgentTape.current?.watch(root.appending(path: "grok/sessions"), named: "updates.jsonl")
        AgentTape.current?.watch(root.appending(path: "work"))
        try bridge.start()
        try runtime.start()
    }

    func open(_ launchToken: String) async throws -> PiSession.ID {
        try await runtime.open(in: work, launchToken: launchToken, name: nil, model: GrokModel.hosted, thinking: nil)
    }

    func stop() async {
        await runtime.stop()()
        bridge.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func transcript(_ session: PiSession) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(session.sessionFile), agent: .grok, from: nil, files: scratchFiles)
    }

    func replies(_ session: PiSession) -> [String] {
        ((try? transcript(session))?.messages ?? []).filter { $0.role == .known(.pi) }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 最近一条回答里有这个词（真模型的措辞不定，不要求刚好是它）
    func replied(_ word: String, in id: PiSession.ID) -> Bool {
        bridge.session(id: id).flatMap { replies($0).last?.contains(word) } == true
    }
}

@MainActor
func withGrokRig(_ body: (GrokRig) async throws -> Void) async throws {
    let rig = try GrokRig()
    do { try await body(rig) } catch { await rig.stop(); throw error }
    await rig.stop()
}
#endif
