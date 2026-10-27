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

    private func key(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".png" }

    private func imageBlock(_ data: Data) -> [String: Any] { ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"] }

    @Test func 图片按原顺序成为正文引用_说明行去掉_图片存进附件目录() throws {
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

        let users = update.messages.filter { $0.role == .known(.user) }
        #expect(users.map(\.text) == ["看这张\n![](cuepad://file/\(key(sent)))", "![](cuepad://file/\(key(pasted)))"])
        #expect(update.recap.pendingPrompt == nil && update.recap.lastPrompt == "看这张" && update.recap.lastReply == "看到了")
        #expect(update.history.displayName == "看这张")
        for data in [sent, pasted] {
            #expect(try Data(contentsOf: #require(store.files.fileURL(for: key(data)))) == data)
        }
    }

    /// 交给 Agent 的附件行（"附件：文件名（路径）"）在会话名与摘要里只留文件名：本机那份在对话里认回文件；别的 Mac 的路径、
    /// 扩展报的首条消息被截断在路径中间的，也不把路径带进标题。
    @Test func 附件行在会话名与摘要里只留文件名() throws {
        let key = try store.files.store(fileAt: try {
            let url = dir.appending(path: "handoff-brief.pdf")
            try Data("%PDF-1.4".utf8).write(to: url)
            return url
        }())
        let local = try #require(store.files.agentLine(key: key, name: "handoff-brief.pdf"))
        let foreign = "附件：录屏.mov（/Users/other/Library/Caches/CuePadAttachments/\(String(repeating: "a", count: 64)).mov）"
        var file = SessionFile(directory: dir)
        try file.append(
            SessionFile.header(),
            SessionFile.user("u1", nil, [["type": "text", "text": "看这份\n\n\(local)"]], at: 1),
            SessionFile.assistant("a1", "u1", text: "看完了", at: 2),
            SessionFile.user("u2", "a1", [["type": "text", "text": "\(foreign)\n这段也看"]], at: 3))

        let update = try PiHistory.index(file: file.url, agent: .pi, from: nil, files: store.files)

        #expect(update.history.displayName == "看这份  handoff-brief.pdf")
        #expect(update.messages.first?.text == "看这份\n\n[handoff-brief.pdf](cuepad://file/\(key))")
        #expect(update.recap.pendingPrompt == "录屏.mov 这段也看")
        #expect(PiSessionName.display(name: nil, firstMessage: String(("看这份\n\n" + local).prefix(60)), folder: "x") == "看这份  handoff-brief.pdf")
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
