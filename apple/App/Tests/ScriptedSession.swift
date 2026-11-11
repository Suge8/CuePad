#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 剧本里的一个会话：假扩展扮演，Cue 送进来的话（带投送 id，认作 Cue 说的）由它记进会话文件，剧本写会话说的，Mac 读会话文件写进库。
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
    private let inbox = Inbox()

    init(_ id: String, on host: RecordingHost, task: Card) {
        self.id = id
        self.host = host
        self.task = task
        cards = [task]
        // 像真扩展那样：收到话开始干活，作答后收起提问、接着干
        let behave = { [inbox] (fake: FakeExtension) in
            let ack = fake.onCommand
            fake.onCommand = { [weak fake] connection, command in
                switch command["t"] as? String {
                case "send":
                    if (command["text"] as? String)?.contains(/表面补丁|双事实源/) == true { inbox.closing.withLock { $0 = true } }
                    fake?.setState(["kind": "thinking"])
                case "answer":
                    if let value = command["value"] as? String { inbox.answers.withLock { $0.append((value, .now)) } }
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

    /// 收到的作答（选项原文或填的字、收到的时刻）：在扩展的 socket 队列上收，换进程也不丢
    nonisolated final class Inbox: Sendable {
        let answers = Mutex<[(value: String, at: Date)]>([])
        /// Cue 问了收口那一问（`CuePrompt.stopsAndFollowUp`），还没答
        let closing = Mutex(false)
    }

    /// Cue 问了收口那一问、还没答。
    var askedToClose: Bool { inbox.closing.withLock { $0 } }

    /// 答收口那一问（真会话会答；剧本的回复是定好的，不会自己接这一句）：复查过、没有要收口的，结果与证据不变。
    func answerClosing(rig: CueHostTests.Rig) async throws {
        inbox.closing.withLock { $0 = false }
        try await settle("对照做法复查过了：没有表面补丁与双事实源，重复分支、多余的防御与测试、没人用了的代码与文档都没有，范围内没有要收口的。上一条的结果与证据不变。", rig: rig)
    }

    /// `window` 里收到的作答（同 `Working.answers`：只认会话收到的）
    func answers(in window: ClosedRange<Date>) -> [String] { inbox.answers.withLock { $0 }.filter { window.contains($0.at) }.map(\.value) }

    func refresh(_ rig: CueHostTests.Rig) async throws {
        cards = [task] + (try await rig.store.tasks(boundTo: id)).flatMap { [$0.task] + ($0.parent.map { [$0] } ?? []) }
        title = try await rig.store.sessions(matching: id).first?.title ?? ""
    }

    /// 做完这一轮歇下，回复是 `reply`。
    func settle(_ reply: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        session.setState(["kind": "idle"])
        try await rig.answered(id, reply: reply)
    }

    /// 这一轮说了 `said` 后停下来问一个选择题（问他的对话框由工具调起：这段话在这一轮的经过里，这一轮没收尾）。
    func ask(said: String, question: String, options: [String], rig: CueHostTests.Rig) async throws {
        try await working(rig)
        try await rig.spoke(said, in: id)
        session.sendInfo(["question": ["id": UUID().uuidString, "kind": "select", "text": question, "options": options]])
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

    /// 在干活写进库。
    private func working(_ rig: CueHostTests.Rig) async throws {
        session.setState(["kind": "thinking"])
        try await eventually("\(id) 在干活写进库") { try await rig.store.sessions(matching: self.id).first?.state.isWorking == true }
    }
}
#endif
