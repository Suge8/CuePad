#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

extension CueHostTests.Rig {
    var rounds: [CueRound] { services.cue.keeper?.rounds ?? [] }

    func working(_ title: String, _ rest: String) async throws -> Working {
        let project = try #require(try await store.projects().first { $0.name == "演示" })
        let first = "\(title)\n\(rest)"
        let task = try await store.createTask(first, in: project.id)
        let id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
        try await store.recordSend(first, to: SendTarget(kind: .piSession, name: title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let session = try await app.host.connect(id, cwd: folder.path, busy: true)
        // 像真扩展那样：作答后收起提问、回到工作中（假扩展默认只回 ack）
        let ack = session.onCommand
        session.onCommand = { [weak session] connection, command in
            if command["t"] as? String == "answer" {
                session?.sendInfo(["question": NSNull()])
                session?.setState(["kind": "thinking"])
            }
            return ack(connection, command)
        }
        session.sendInfo(["name": title])
        let prompt = PiChatMessage(sessionID: id, entryID: "u1", seq: 1, role: .user, text: first, at: .now, deliveryID: delivery)
        try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [prompt], recap: PiRecap(pendingPrompt: oneLine(first))))
        try await eventually("会话在干活写进库") { try await self.store.sessions(matching: id).first?.state.isWorking == true }
        return Working(task: task, session: session, prompt: prompt)
    }

    /// 会话发来几张效果图（默认按文件名画，见 `mockShot`）。
    @MainActor @discardableResult
    func shots(_ files: [(name: String, title: String)], from work: Working, drawing: @MainActor (String) throws -> Data = mockShot) async throws -> [PiPreviewAdded] {
        var sent: [(url: URL, title: String)] = []
        for (name, title) in files {
            let url = app.directory.appending(path: name)
            try drawing(name).write(to: url)
            sent.append((url, title))
        }
        return try await store.addPreviews(sent, sessionID: work.id)
    }

    func reply(_ work: Working, _ text: String) -> PiChatMessage {
        PiChatMessage(sessionID: work.id, entryID: "a1", seq: 2, role: .pi, text: text, at: .now)
    }

    /// 会话做完这一轮歇下，回复是 `reply`。
    func settle(_ work: Working, reply text: String) async throws {
        work.session.setState(["kind": "idle"])
        try await answered(work.id, prompt: oneLine(work.prompt.text), reply: text, messages: [work.prompt, reply(work, text)])
    }

    /// 他 `ago` 秒前直接在会话里（终端里打的，不带 Cue 的发送记录）说了 `said`，会话做完他这一轮、回复 `reply` 后歇下。
    func settleHisTurn(_ work: Working, said: String, ago: TimeInterval, reply text: String) async throws {
        let first = reply(work, "后端做完了：发重置邮件的接口、令牌校验与限流，14 个测试全过。")
        let his = PiChatMessage(sessionID: work.id, entryID: "u2", seq: 3, role: .user, text: said, at: .now - ago)
        let answer = PiChatMessage(sessionID: work.id, entryID: "a2", seq: 4, role: .pi, text: text, at: .now)
        work.session.setState(["kind": "idle"])
        try await answered(work.id, prompt: said, reply: text, messages: [work.prompt, first, his, answer])
    }

    /// 他 `ago` 秒前直接在会话里说了 `his`，之后 Cue 说了 `cue`（发送记录是 Cue 的）开了这一轮，做完回复 `reply` 后歇下。
    func settleCueTurn(_ work: Working, his: String, ago: TimeInterval, cue: String, reply text: String) async throws {
        let delivery = UUID()
        try await store.recordSend(cue, to: SendTarget(kind: .piSession, name: work.task.heading, ref: work.id), card: work.task.id, delivery: delivery, origin: .known(.cue))
        let messages = [
            work.prompt, reply(work, "重置邮件发出去了，测试在补。"),
            PiChatMessage(sessionID: work.id, entryID: "u2", seq: 3, role: .user, text: his, at: .now - ago),
            PiChatMessage(sessionID: work.id, entryID: "a2", seq: 4, role: .pi, text: "接口与邮件都好了，在补测试。", at: .now - ago + 60),
            PiChatMessage(sessionID: work.id, entryID: "u3", seq: 5, role: .user, text: cue, at: .now - 120, deliveryID: delivery),
            PiChatMessage(sessionID: work.id, entryID: "a3", seq: 6, role: .pi, text: text, at: .now),
        ]
        work.session.setState(["kind": "idle"])
        try await answered(work.id, prompt: cue, reply: text, messages: messages)
    }

    /// 会话这一轮说了 `said` 后停下来问一个选择题。
    func ask(_ work: Working, said: String, question: String, options: [String]) async throws {
        try await store.writePiTranscript(PiTranscript(
            sessionID: work.id, messages: [work.prompt, reply(work, said)], recap: PiRecap(pendingPrompt: oneLine(work.prompt.text))))
        work.session.sendInfo(["question": ["id": "p1", "kind": "select", "text": question, "options": options]])
        work.session.setState(["kind": "waiting_user", "title": question])
    }
}

func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }

func sentences(_ text: String) -> Int {
    text.split { "。！？!?\n".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
}
#endif
