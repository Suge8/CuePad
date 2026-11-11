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
        let file = try #require(app.host.sessionFiles[id])
        try file.user(first, delivery: delivery.uuidString)
        try await read(first, in: id)
        try await eventually("会话在干活写进库") { try await self.store.sessions(matching: id).first?.state.isWorking == true }
        return Working(task: task, session: session, file: file)
    }

    /// 等 Mac 把会话文件里你的这句话读进库（对话里最后一句你的话就是它）：之后叫醒的 Cue 看得到它与它之前的对话。
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

    /// 会话做完这一轮歇下，回复是 `reply`。
    func settle(_ work: Working, reply text: String) async throws {
        work.session.setState(["kind": "idle"])
        try await answered(work.id, reply: text)
    }

    /// 会话收到 Cue 刚说的那句（假扩展已记进会话文件）接着干，做完回复 `reply` 后又歇下。
    func resettle(_ work: Working, reply text: String) async throws {
        work.session.setState(["kind": "thinking"])
        try await eventually("会话又在干活写进库") { try await self.store.sessions(matching: work.id).first?.state.isWorking == true }
        try await settle(work, reply: text)
    }

    /// 这件事返工过几轮：每一轮会话交回 `handed`、Cue 接着说了 `cue`（发送记录是 Cue 的）；最后那句开的这一轮做完，回复 `reply` 后歇下。
    func settleReworked(_ work: Working, rounds: [(handed: String, cue: String)], reply text: String) async throws {
        var at = Date.now - Double(rounds.count) * 300
        for round in rounds {
            let delivery = UUID()
            try await store.recordSend(
                round.cue, to: SendTarget(kind: .piSession, name: work.task.heading, ref: work.id), card: work.task.id, delivery: delivery, origin: .known(.cue))
            try work.file.reply(round.handed, at: at)
            try work.file.user(round.cue, delivery: delivery.uuidString, at: at + 60)
            at += 300
        }
        try await settle(work, reply: text)
    }

    /// 他 `ago` 秒前直接在会话里（终端里打的，不带 Cue 的发送记录）说了 `said`，会话做完他这一轮、回复 `reply` 后歇下。
    func settleHisTurn(_ work: Working, said: String, ago: TimeInterval, reply text: String) async throws {
        try work.file.reply("后端做完了：发重置邮件的接口、令牌校验与限流，14 个测试全过。", at: .now - ago - 60)
        try work.file.user(said, at: .now - ago)
        work.session.setState(["kind": "idle"])
        try await answered(work.id, reply: text)
    }

    /// 他 `ago` 秒前直接在会话里说了 `his`，之后 Cue 说了 `cue`（发送记录是 Cue 的）开了这一轮，做完回复 `reply` 后歇下。
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

    /// 会话这一轮说了 `said` 后停下来问一个选择题（问他的对话框由工具调起：这段话在这一轮的经过里，这一轮没收尾）。
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
