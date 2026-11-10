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
        let request = try await store.startLeaf(task.id, host: services.hostID, cue: true)
        #expect(try await store.outcome(of: request).status == .known(.succeeded))
        let started = try await eventually(store, { try $0.card(task.id) }) { $0?.piSessionID != nil }
        let id = try #require(started?.piSessionID)
        let session = try #require(app.host.extensions[id])
        session.setState(["kind": "thinking"])
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
        let file = try #require(app.host.sessionFiles[id])
        try await read(first, in: id)
        try await eventually("会话在干活写进库") { try await self.store.sessions(matching: id).first?.state.isWorking == true }
        return Working(task: task, session: session, file: file)
    }

    func read(_ text: String, in sessionID: String) async throws {
        try await eventually("「\(text.prefix(20))」读进库") {
            try await self.store.piMessages(of: sessionID).last { $0.role == .known(.user) }?.text == text
        }
    }

    /// 会话这一轮说了 `said`、接着调工具（问他的对话框由工具调起）：写进会话文件，等 Mac 读进这一轮的经过再往下（真会话里这段话先落盘、对话框才弹出），
    /// 叫醒的 Cue 看得到它。
    func spoke(_ said: String, in sessionID: String) async throws {
        try app.host.sessionFiles[sessionID]!.spoke(said)
        let shown = said.trimmingCharacters(in: .whitespacesAndNewlines).clipped(PiChatMessage.Tools.saidLimit)
        try await eventually("「\(said.prefix(20))」读进这一轮的经过") {
            try await self.store.sessions(matching: sessionID).first?.pendingTools?.items.last { $0.kind == .said }?.target == shown
        }
    }

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

    func settle(_ work: Working, reply text: String) async throws {
        work.session.setState(["kind": "idle"])
        try await answered(work.id, reply: text)
    }

    func settleHisTurn(_ work: Working, said: String, ago: TimeInterval, reply text: String) async throws {
        try work.file.reply("后端做完了：发重置邮件的接口、令牌校验与限流，14 个测试全过。", at: .now - ago - 60)
        try work.file.user(said, at: .now - ago)
        work.session.setState(["kind": "idle"])
        try await answered(work.id, reply: text)
    }

    func settleCueTurn(_ work: Working, his: String, ago: TimeInterval, cue: String, reply text: String) async throws {
        let delivery = UUID()
        try await store.recordSend(cue, to: SendTarget(kind: .piSession, name: work.task.heading, ref: work.id), card: work.task.id, delivery: delivery, origin: .known(.cue))
        try work.file.reply("重置邮件发出去了，测试在补。", at: .now - ago - 60)
        try work.file.user(his, at: .now - ago)
        try work.file.reply("接口与邮件都好了，在补测试。", at: .now - ago + 60)
        try work.file.user(cue, delivery: delivery.uuidString, at: .now - 120)
        work.session.setState(["kind": "idle"])
        try await answered(work.id, reply: text)
    }

    func ask(_ work: Working, said: String, question: String, options: [String]) async throws {
        try await spoke(said, in: work.id)
        work.session.sendInfo(["question": ["id": "p1", "kind": "select", "text": question, "options": options]])
        work.session.setState(["kind": "waiting_user", "title": question])
    }
}

func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }

func sentences(_ text: String) -> Int {
    text.split { "。！？!?\n".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
}

/// 派活的回复报了模型或强度（"sonnet""low 强度"这类）：他没问，经过那一行已写着用哪家开。
func reportsConfig(_ text: String) -> Bool {
    text.lowercased().contains(/强度|模型|\b(low|medium|high|xhigh|max|sonnet|opus|haiku|fable|gpt)\b/)
}
#endif
