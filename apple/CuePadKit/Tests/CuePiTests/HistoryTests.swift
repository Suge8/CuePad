#if os(macOS)
import CueTestSupport
import Foundation
import Synchronization
import Testing
import CueStore
@testable import CuePi

struct HistoryTests {
    let dir: URL
    init() throws { dir = try makeTempDirectory() }

    private func index(_ file: SessionFile, from checkpoint: PiHistoryCheckpoint? = nil) throws -> PiHistoryUpdate {
        try PiHistory.index(file: file.url, from: checkpoint)
    }

    // MARK: 会话标题：与活动会话、Pi 会话列表同一规则（名字 → 文件里首条用户消息 → 工作目录名）

    @Test func titleIsTheFirstUserMessageInFileOrderLikePisSessionList() throws {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(cwd: "/work/proj"),
            SessionFile.user("u1", nil, "first prompt", at: 1),
            SessionFile.assistant("a1", "u1", text: "reply one", at: 2),
            SessionFile.user("u2", "a1", "later prompt", at: 3),
            SessionFile.assistant("t2", "u2", text: "checking", stop: "toolUse", at: 4),
            SessionFile.toolResult("r2", "t2", at: 5),
            SessionFile.user("u0", nil, "rewritten first", at: 6))  // 回到开头另起分支：Pi 的列表仍取文件里的第一条
        #expect(try index(f).history.displayName == "first prompt")

        try f.append(SessionFile.info("n1", "u0", name: "Refactor auth", at: 7))
        #expect(try index(f).history.displayName == "Refactor auth")
    }

    // MARK: 命令在会话文件里留下的

    /// 对话只来自会话文件，与终端一致：压缩留下一条 compaction（终端里是压缩摘要那一行），对话里是一行系统行；
    /// 换模型、改强度、改名只是设置条目，终端的对话里没有它们，这里也没有；模板与 skill 展开成一条普通的用户消息（没有投送请求 id）。
    @Test func compactionIsASystemLineAndSettingEntriesAreNotConversation() throws {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(),
            SessionFile.user("u1", nil, "first", at: 1),
            SessionFile.assistant("a1", "u1", text: "reply one", at: 2),
            SessionFile.entry("model_change", "m1", "a1", at: 3, ["provider": "fake", "modelId": "echo-b"]),
            SessionFile.entry("thinking_level_change", "t1", "m1", at: 4, ["thinkingLevel": "high"]),
            SessionFile.info("n1", "t1", name: "改名", at: 5),
            SessionFile.compaction("c1", "n1", tokensBefore: 63_000, at: 6),
            SessionFile.compaction("c2", "c1", tokensBefore: 950, at: 7),
            SessionFile.compaction("c3", "c2", tokensBefore: nil, at: 8),
            SessionFile.user("u2", "c3", "Say hello to world.", at: 9))

        let update = try index(f)

        #expect(update.messages.map(\.role.known) == [.user, .pi, .system, .system, .system, .user])
        #expect(update.messages[2...4].map(\.text) == ["已压缩上下文", "已压缩上下文", "已压缩上下文"])
        #expect(update.messages[2].id == PiChatMessage.recordID(sessionID: update.sessionID, entryID: "c1") && update.messages[2].seq == 7 && update.messages[2].at == SessionFile.date(6))
        #expect(update.messages[5].text == "Say hello to world." && update.messages[5].deliveryID == nil)
        #expect(update.recap.lastReply == "reply one" && update.recap.pendingPrompt == "Say hello to world.")  // 系统行不动问答摘要
    }

    // MARK: 增量

    @Test func halfWrittenLineIsNotConsumedUntilItsNewlineArrives() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header())
        let base = try index(f)
        let prompt = SessionFile.user("u1", nil, "whole prompt", at: 2)
        let cut = prompt.index(prompt.startIndex, offsetBy: prompt.count / 2)
        try f.appendRaw(String(prompt[..<cut]))

        let partial = try index(f, from: base.checkpoint)
        #expect(partial.bytesRead == 0 && partial.checkpoint.offset == base.checkpoint.offset)
        #expect(partial.history.firstMessage == nil)

        try f.appendRaw(String(prompt[cut...]) + "\n")
        let done = try index(f, from: partial.checkpoint)
        #expect(done.history.displayName == "whole prompt")
        #expect(done.bytesRead == prompt.utf8.count + 1)
    }

    @Test(arguments: ["shorter", "same-size-different-content"])
    func replacedFileIsRebuiltInsteadOfResumedFromAStaleOffset(kind: String) throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(id: "old"), SessionFile.user("u1", nil, "old prompt that is fairly long", at: 1),
                     SessionFile.assistant("a1", "u1", text: "old reply", at: 2))
        let old = try index(f)

        let replacement: [String] = kind == "shorter"
            ? [SessionFile.header(id: "new"), SessionFile.user("x1", nil, "n", at: 1)]
            : [SessionFile.header(id: "new"), SessionFile.user("x1", nil, "new prompt that is fairly long", at: 1),
               SessionFile.assistant("y1", "x1", text: "new reply", at: 2)]
        try f.write(text: replacement.joined(separator: "\n") + "\n")

        let rebuilt = try index(f, from: old.checkpoint)
        #expect(rebuilt.history == (try index(f)).history)
        #expect(rebuilt.history.sessionID == "new")
    }
}

#endif
