#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 会话被结束后又被话唤醒时 Mac 照会话文件重开一个进程（`RecordingHost.resume`）：剧本跟着此刻连着桥的那一个演。
@MainActor
final class ScriptedSession {
    let id: String
    let task: Card
    private let host: RecordingHost
    var session: FakeExtension { host.extensions[id]! }
    private(set) var cards: [Card] = []
    private(set) var title = ""
    private let inbox = Inbox()

    init(_ id: String, on host: RecordingHost, task: Card) {
        self.id = id
        self.host = host
        self.task = task
        cards = [task]
        let behave = { [inbox] (fake: FakeExtension) in
            let ack = fake.onCommand
            fake.onCommand = { [weak fake] connection, command in
                switch command["t"] as? String {
                case "send":
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

    nonisolated final class Inbox: Sendable {
        let answers = Mutex<[(value: String, at: Date)]>([])
    }

    func answers(in window: ClosedRange<Date>) -> [String] { inbox.answers.withLock { $0 }.filter { window.contains($0.at) }.map(\.value) }

    func refresh(_ rig: CueHostTests.Rig) async throws {
        cards = [task] + (try await rig.store.tasks(boundTo: id)).flatMap { [$0.task] + ($0.parent.map { [$0] } ?? []) }
        title = try await rig.store.sessions(matching: id).first?.title ?? ""
    }

    func settle(_ reply: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        session.setState(["kind": "idle"])
        try await rig.answered(id, reply: reply)
    }

    func ask(said: String, question: String, options: [String], rig: CueHostTests.Rig) async throws {
        try await working(rig)
        try await rig.spoke(said, in: id)
        session.sendInfo(["question": ["id": UUID().uuidString, "kind": "select", "text": question, "options": options]])
        session.setState(["kind": "waiting_user", "title": question])
    }

    func fail(_ error: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        session.setState(["kind": "error", "error": error])
    }

    func deliver(_ png: Data, title: String, rig: CueHostTests.Rig) async throws {
        let file = rig.app.directory.appending(path: "\(title).png")
        try png.write(to: file)
        _ = try await rig.store.addPreviews([(file, title)], sessionID: id)
    }

    private func working(_ rig: CueHostTests.Rig) async throws {
        session.setState(["kind": "thinking"])
        try await eventually("\(id) 在干活写进库") { try await rig.store.sessions(matching: self.id).first?.state.isWorking == true }
    }
}
#endif
