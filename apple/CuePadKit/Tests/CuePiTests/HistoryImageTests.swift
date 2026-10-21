#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 你的消息里的图片：会话文件是唯一来源，读出来存进附件目录，对话里只留引用；终端里贴的图片也一样。
struct HistoryImageTests {
    let fixture = try! Fixture()
    let dir = try! makeTempDirectory()
    var store: CueStore { fixture.store }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func imageBlock(_ data: Data) -> [String: Any] { ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"] }

    @Test func 图片按原顺序成为正文引用_说明行去掉_图片存进附件目录并随对话登记() async throws {
        let sent = pngData(width: 8, height: 8, shade: 0.2)
        let pasted = pngData(width: 8, height: 8, shade: 0.7)
        let note = "[Image: original 3000x2000, displayed at 1500x1000. Multiply coordinates by 2.00 to map to original image.]"
        var file = SessionFile(directory: dir)
        try file.append(
            SessionFile.header(),
            SessionFile.user("u1", nil, [["type": "text", "text": "看这张\n\n\(note)"], imageBlock(sent)], at: 1),
            SessionFile.assistant("a1", "u1", text: "看到了", at: 2),
            SessionFile.user("u2", "a1", [imageBlock(pasted)], at: 3))

        let update = try PiHistory.index(file: file.url, agent: .pi, from: nil, files: store.files)
        try await store.writePiTranscript(update.transcript)

        let users = update.messages.filter { $0.role == .known(.user) }
        #expect(users.map(\.text) == ["看这张\n![](cuepad://img/\(hash(sent)))", "![](cuepad://img/\(hash(pasted)))"])
        #expect(update.recap.pendingPrompt == nil && update.recap.lastPrompt == "看这张" && update.recap.lastReply == "看到了")
        #expect(update.history.displayName == "看这张")
        for data in [sent, pasted] {
            #expect(try store.files.original(hash: hash(data)) == data)
            #expect(try await store.hasAttachment(hash(data)))
        }
    }

    /// 活动会话的首条消息来自扩展（原文，可能被截断在说明行中间）：显示名同样不带说明行。
    @Test func 说明行不进会话名() {
        let note = "[Image: original 3000x2000, displayed at 1500x1000. Multiply coordinates by 2.00 to map to original image.]"
        #expect(PiSessionName.display(name: nil, firstMessage: "看这张\n\n" + note, folder: "x") == "看这张")
        #expect(PiSessionName.display(name: nil, firstMessage: "看这张\n\n[Image: original 3000x2", folder: "x") == "看这张")
        #expect(PiSessionName.display(name: nil, firstMessage: "看这张\n\n" + note + "\n\n", folder: "x") == "看这张")
        #expect(PiSessionName.display(name: nil, firstMessage: "[Image converted from image/webp to image/png.]", folder: "x") == "x")
    }
}
#endif
