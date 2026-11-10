#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import ImageIO
import Testing
@testable import CuePad

/// 各家同一条路（`PiHistory.Transcript.toolImages`）：会话文件的形状照各家真机读图时写下的（Codex 0.166 的 view_image、Grok 1.0.70 的 read_file）。
@MainActor
@Suite(.releasesLibraries)
struct ToolImageTests {
    @Test func 工具结果带图的一轮_经过下有缩略图_点开全屏_同一张只存一份() async throws {
        let app = TestApp()
        defer { app.services.cancelBackgroundWork() }
        let store = app.services.store, files = store.files
        let file = app.directory.appending(path: "shots.jsonl"), log = SessionFile(url: file, sessionID: "s", cwd: app.directory.path)
        try log.reset()
        let shot = pngData(width: 3200, height: 2000, shade: 0.3), icon = pngData(width: 40, height: 40, shade: 0.6)
        try log.user("截个图看看")
        // 清单只列 30 条不落结果的调用：先跑满，带图的那几步照样列上
        for step in 0..<31 { try log.tool("bash", id: "b\(step)", arguments: ["command": "ls \(step)"]) }
        try log.tool("read", id: "c1", arguments: ["path": "shot.png"], images: [shot])
        try log.tool("read", id: "c2", arguments: ["path": "icon.png"], images: [icon])
        try log.tool("read", id: "c3", arguments: ["path": "shot.png"], images: [shot])
        try log.reply("截好了")
        let update = try PiHistory.index(file: file, agent: .pi, from: nil, files: files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(update)); $0.finish() }, agent: .pi)

        let round = try #require(try await store.piMessages(of: "s").last { $0.role == .known(.pi) })
        let images = try #require(round.tools?.images)
        #expect(images.count == 2)
        #expect(round.tools?.steps == 33)  // 31 条命令 + 读两个文件（同一个文件读两次只算一次）

        let stored = try JSONEncoder().encode(update.checkpoint)
        var old = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        old["rules"] = 1
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PiHistoryCheckpoint.self, from: JSONSerialization.data(withJSONObject: old)) }
        #expect(try JSONDecoder().decode(PiHistoryCheckpoint.self, from: stored) == update.checkpoint)
        let shrunk = try #require(files.fileURL(for: images[0]))
        let size = try #require(CGImageSourceCreateWithURL(shrunk as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 1600 && size[kCGImagePropertyPixelHeight] as? Int == 1000)
        #expect(try Data(contentsOf: #require(files.fileURL(for: images[1]))) == icon)
        for key in images { #expect(try await store.hasAttachment(key)) }

        let workspace = Workspace(services: app.services)
        let all = images.map { DraftFile(key: $0, name: "") }
        workspace.openAttachment(all[1], among: all, group: "chat-" + images.joined(separator: ","), with: nil)
        #expect(workspace.preview?.preview.key == images[1] && workspace.preview?.batch.map(\.key) == images)
    }

    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func lines(_ objects: [[String: Any]]) throws -> Data {
        try objects.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1) + Data("\n".utf8) }
    }

    /// Codex：view_image 在会话文件里只是一条 `ImageView`（带文件的地址），图从那个文件取。
    private static func codex(_ dir: URL, shot: URL) throws -> URL {
        let at = stamp.format(.now)
        func event(_ payload: [String: Any]) -> [String: Any] { ["timestamp": at, "type": "event_msg", "payload": payload] }
        let file = dir.appending(path: "rollout-2026-11-06T23-12-32-01a1b16b-27bb-7f93-80e2-87d9dbcc57be.jsonl")
        try lines([
            ["timestamp": at, "type": "session_meta", "payload": ["id": "s", "cwd": dir.path]],
            event(["type": "task_started"]),
            event(["type": "item_completed", "item": ["type": "UserMessage", "id": "u1", "content": [["type": "text", "text": "看看这张图"]]]]),
            event(["type": "item_completed", "item": ["type": "ImageView", "id": "v1", "path": shot.absoluteString]]),
            event(["type": "item_completed", "item": ["type": "AgentMessage", "id": "a1", "content": [["type": "Text", "text": "蓝色"]], "phase": "final_answer"]]),
        ]).write(to: file)
        return file
    }

    /// Grok：读图那一步做完时，ACP 的图片块在 `tool_call_update` 的 content 里。
    private static func grok(_ dir: URL, shot: URL) throws -> URL {
        let file = dir.appending(path: "sessions/%2Fw/s/updates.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func update(_ update: [String: Any], prompt: String? = nil) -> [String: Any] {
            ["timestamp": Date.now.timeIntervalSince1970, "method": "session/update",
             "params": ["sessionId": "s", "update": update, "_meta": prompt.map { ["promptId": $0] } ?? [:]]]
        }
        let image = try Data(contentsOf: shot).base64EncodedString()
        try lines([
            update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "看看这张图"]]),
            update(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "read_file", "rawInput": ["target_file": shot.path]], prompt: "p1"),
            update(["sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed",
                    "content": [["type": "content", "content": ["type": "image", "data": image, "mimeType": "image/png"]]]], prompt: "p1"),
            update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "蓝色"]], prompt: "p1"),
            update(["sessionUpdate": "turn_completed", "stop_reason": "end_turn"], prompt: "p1"),
        ]).write(to: file)
        return file
    }

    @Test(arguments: [AgentKind.codex, .grok])
    func 别家会话里工具结果的图_同样缩小后挂在那一轮经过下(agent: AgentKind) async throws {
        let app = TestApp()
        defer { app.services.cancelBackgroundWork() }
        let store = app.services.store, files = store.files
        let shot = app.directory.appending(path: "shot.png")
        try pngData(width: 2400, height: 1200, shade: 0.4).write(to: shot)
        let file = try agent == .codex ? Self.codex(app.directory, shot: shot) : Self.grok(app.directory, shot: shot)
        let update = try PiHistory.index(file: file, agent: agent, from: nil, files: files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(update)); $0.finish() }, agent: agent)

        let round = try #require(try await store.piMessages(of: "s").last { $0.role == .known(.pi) })
        let key = try #require(round.tools?.images.first)
        let size = try #require(
            files.fileURL(for: key).flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
                as? [CFString: Any])
        #expect(round.tools?.images.count == 1 && size[kCGImagePropertyPixelWidth] as? Int == 1600)
        #expect(try await store.hasAttachment(key))
    }
}
#endif
