#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 剧本里的一个会话：假扩展扮演，对话按 Cue 真送进来的话（带投送 id，认作 Cue 说的）与剧本的回复累积，像 Mac 读会话文件那样写进库。
/// 会话被结束后又被话唤醒时 Mac 照会话文件重开一个进程（`RecordingHost.resume`）：剧本跟着此刻连着桥的那一个演。
@MainActor
final class ScriptedSession {
    let id: String
    let task: Card
    private let host: RecordingHost
    /// 此刻连着桥的那个进程
    var session: FakeExtension { host.extensions[id]! }
    /// 绑着这个会话的任务与步骤、会话名（判 say 给的是谁）；判定前 `refresh`
    private(set) var cards: [Card] = []
    private(set) var title = ""
    private var messages: [PiChatMessage] = []
    private let inbox = Inbox()

    /// `history`：会话里此前的对话（多日剧本预置的，带当时的时刻）。接手前已送进来的话（开场白）记进待收。
    init(_ id: String, on host: RecordingHost, task: Card, history: [PiChatMessage] = []) {
        self.id = id
        self.host = host
        self.task = task
        cards = [task]
        messages = history
        inbox.said.withLock { $0 = host.extensions[id]!.commands.map(\.json).compactMap(Inbox.said) }
        // 像真扩展那样：收到话开始干活，作答后收起提问、接着干
        let behave = { [inbox] (fake: FakeExtension) in
            let ack = fake.onCommand
            fake.onCommand = { [weak fake] connection, command in
                switch command["t"] as? String {
                case "send":
                    if let said = Inbox.said(command) { inbox.said.withLock { $0.append(said) } }
                    fake?.setState(["kind": "thinking"])
                case "answer":
                    fake?.sendInfo(["question": NSNull()])
                    fake?.setState(["kind": "thinking"])
                default: break
                }
                return ack(connection, command)
            }
        }
        behave(host.extensions[id]!)
        host.behaviors[id] = behave
    }

    /// 送进来还没记进对话的话（文字、投送 id）：在扩展的 socket 队列上收，换进程也不丢
    nonisolated final class Inbox: Sendable {
        let said = Mutex<[(text: String, delivery: UUID?)]>([])

        static func said(_ command: [String: Any]) -> (text: String, delivery: UUID?)? {
            guard command["t"] as? String == "send" else { return nil }
            return (command["text"] as? String ?? "", (command["deliveryId"] as? String).flatMap(UUID.init(uuidString:)))
        }
    }

    func refresh(_ rig: CueHostTests.Rig) async throws {
        cards = [task] + (try await rig.store.tasks(boundTo: id)).flatMap { [$0.task] + ($0.parent.map { [$0] } ?? []) }
        title = try await rig.store.sessions(matching: id).first?.title ?? ""
    }

    /// 做完这一轮歇下，回复是 `reply`。
    func settle(_ reply: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        append(.pi, reply)
        session.setState(["kind": "idle"])
        try await rig.answered(id, prompt: oneLine(lastPrompt), reply: reply, messages: messages)
    }

    /// 这一轮说了 `said` 后停下来问一个选择题。
    func ask(said: String, question: String, options: [String], rig: CueHostTests.Rig) async throws {
        try await working(rig)
        append(.pi, said)
        try await rig.store.writePiTranscript(PiTranscript(sessionID: id, messages: messages, recap: PiRecap(pendingPrompt: oneLine(lastPrompt))))
        session.sendInfo(["question": ["id": "q\(messages.count)", "kind": "select", "text": question, "options": options]])
        session.setState(["kind": "waiting_user", "title": question])
    }

    /// 这一轮出错停下。
    func fail(_ error: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        session.setState(["kind": "error", "error": error])
    }

    /// 发一张图到手机。
    func deliver(_ png: Data, title: String, rig: CueHostTests.Rig) async throws {
        let file = rig.app.directory.appending(path: "\(title).png")
        try png.write(to: file)
        _ = try await rig.store.addPreviews([(file, title)], sessionID: id)
    }

    /// 收下 Cue 送进来的话（像会话文件那样记成带投送 id 的一条），在干活写进库。
    private func working(_ rig: CueHostTests.Rig) async throws {
        for said in inbox.said.withLock({ said in defer { said = [] }; return said }) {
            append(.user, said.text, delivery: said.delivery)
        }
        session.setState(["kind": "thinking"])
        try await eventually("\(id) 在干活写进库") { try await rig.store.sessions(matching: self.id).first?.state.isWorking == true }
    }

    private var lastPrompt: String { messages.last { $0.role == .known(.user) }?.text ?? "" }

    private func append(_ role: PiChatRole, _ text: String, delivery: UUID? = nil) {
        let seq = Int64(messages.count + 1)
        messages.append(PiChatMessage(sessionID: id, entryID: "e\(seq)", seq: seq, role: role, text: text, at: .now, deliveryID: delivery))
    }
}
#endif
