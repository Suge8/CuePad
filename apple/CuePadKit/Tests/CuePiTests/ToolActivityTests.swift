#if os(macOS)
import Foundation
import Testing
import CueStore
@testable import CuePi

/// 每一轮 Agent 的工具活动汇成一份紧凑摘要，随回答那条消息出来：分几类、各几个、失败几个、清单里每条是什么。
/// 会话文件按 Pi 真实写出的键序造（工具结果行：role、toolCallId、toolName、content、isError、timestamp）。
struct ToolActivityTests {
    let dir: URL
    init() throws { dir = try makeTempDirectory() }

    private static func call(_ id: String, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ["type": "toolCall", "id": id, "name": name, "arguments": arguments]
    }

    /// 一条带工具调用的助手消息（中途调工具）。
    private static func calls(_ id: String, _ parent: String, _ blocks: [[String: Any]], at second: Int) -> String {
        SessionFile.line(["type": "message", "id": id, "parentId": parent, "timestamp": SessionFile.stamp(second),
                          "message": ["role": "assistant", "stopReason": "toolUse", "timestamp": second, "content": blocks]])
    }

    /// Pi 写出的工具结果行：isError 在 content 之后、行尾（后面还有 durationMs、timestamp）。
    private static func result(_ id: String, _ parent: String, call: String, name: String, failed: Bool = false, output: String = "输出", at second: Int) -> String {
        #"{"type":"message","id":"\#(id)","parentId":"\#(parent)","timestamp":"\#(SessionFile.stamp(second))","message":{"role":"toolResult","toolCallId":"\#(call)","toolName":"\#(name)","content":[{"type":"text","text":"\#(output)"}],"isError":\#(failed),"durationMs":12,"timestamp":\#(second)}}"#
    }

    private func index(_ file: SessionFile, from checkpoint: PiHistoryCheckpoint? = nil) throws -> PiHistoryUpdate {
        try PiHistory.index(file: file.url, from: checkpoint)
    }

    /// 读文件、改文件、跑命令、搜索、别的工具，其中一条命令失败：分类计数，失败的不算成功。
    private func busyRound() throws -> SessionFile {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(cwd: "/work/x"), SessionFile.user("u1", nil, "收拾一下", at: 1),
            Self.calls("t1", "u1", [
                Self.call("c1", "read", ["path": "/work/x/Sources/a.swift"]),
                Self.call("c2", "read", ["path": "Sources/b.swift"]),
                Self.call("c3", "read", ["path": "/work/x/Sources/a.swift"]),
                Self.call("c4", "edit", ["path": "/work/x/Sources/a.swift", "edits": [["oldText": "one\ntwo\nthree", "newText": "one\n2\nthree\nfour"]]]),
                Self.call("c5", "write", ["path": "/work/x/NOTES.md", "content": "a\nb\nc\n"]),
                Self.call("c6", "bash", ["command": "\nswift test --filter Foo\nrm -rf build"]),
                Self.call("c7", "bash", ["command": "false"]),
                Self.call("c8", "grep", ["pattern": "TODO"]),
                Self.call("c9", "subagents", ["action": "start"]),
            ], at: 2),
            Self.result("r1", "t1", call: "c1", name: "read", at: 3), Self.result("r2", "r1", call: "c2", name: "read", at: 3),
            Self.result("r3", "r2", call: "c3", name: "read", at: 3), Self.result("r4", "r3", call: "c4", name: "edit", at: 4),
            Self.result("r5", "r4", call: "c5", name: "write", at: 4), Self.result("r6", "r5", call: "c6", name: "bash", at: 5),
            Self.result("r7", "r6", call: "c7", name: "bash", failed: true, output: "exit 1", at: 5),
            Self.result("r8", "r7", call: "c8", name: "grep", at: 5), Self.result("r9", "r8", call: "c9", name: "subagents", at: 6),
            SessionFile.assistant("a1", "r9", text: "收拾好了", at: 7))
        return f
    }

    @Test func aRoundsToolsAreClassifiedCountedAndListedWithoutOutput() throws {
        let tools = try #require(try index(try busyRound()).messages.last?.tools)

        // 同一个文件读两次、改两次只算一个；失败的单独记，不进各类计数
        #expect(tools.reads == 2 && tools.edits == 2 && tools.commands == 1 && tools.searches == 1 && tools.others == 1 && tools.failed == 1)
        #expect(tools.items.map(\.kind) == [.read, .read, .edit, .edit, .command, .command, .search, .other])
        // 路径写成相对工作目录的；命令取第一个非空行；其他工具写工具名
        #expect(tools.items.map(\.target) == ["Sources/a.swift", "Sources/b.swift", "Sources/a.swift", "NOTES.md", "swift test --filter Foo", "false", "TODO", "subagents"])
        #expect(tools.items.map(\.failed) == [false, false, false, false, false, true, false, false])
        // 能从参数算出的改动行数：替换里 "two" 换成 "2" 并多一行 → +2 −1；整文件写入只有 +3
        #expect(tools.items[2].added == 2 && tools.items[2].removed == 1)
        #expect(tools.items[3].added == 3 && tools.items[3].removed == nil)
        #expect(tools.items[0].added == nil)
    }

    /// 参数长得不对（不是对象、字段类型不对）的调用照样计数，不让整条消息读不出来。
    @Test func oddArgumentsStillCountAndNeverCostTheMessage() throws {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(cwd: "/work/x"), SessionFile.user("u1", nil, "怪参数", at: 1),
            Self.calls("t1", "u1", [["type": "toolCall", "id": "c1", "name": "bash", "arguments": "ls"], Self.call("c2", "read", ["path": 7])], at: 2),
            SessionFile.assistant("a1", "t1", text: "读完了", at: 3))
        let update = try index(f)
        #expect(update.messages.last?.text == "读完了" && update.messages.last?.tools?.commands == 1 && update.messages.last?.tools?.reads == 1)
    }

    /// Pi 以后换了工具结果行的键序（isError 提前、toolCallId 挪到长输出之后、role 不在行首）也读得对：快速路径认不出就完整解码。
    @Test func aReorderedToolResultLineStillSaysWhichCallFailed() throws {
        let output = String(repeating: "输出", count: 400)
        func reordered(_ id: String, _ parent: String, call: String, failed: Bool, at second: Int) -> String {
            #"{"type":"message","id":"\#(id)","parentId":"\#(parent)","timestamp":"\#(SessionFile.stamp(second))","message":{"isError":\#(failed),"timestamp":\#(second),"content":[{"type":"text","text":"\#(output)"}],"toolName":"bash","role":"toolResult","toolCallId":"\#(call)"}}"#
        }
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(cwd: "/work/x"), SessionFile.user("u1", nil, "跑两条", at: 1),
            Self.calls("t1", "u1", [Self.call("c1", "bash", ["command": "ls"]), Self.call("c2", "bash", ["command": "false"])], at: 2),
            reordered("r1", "t1", call: "c1", failed: false, at: 3), reordered("r2", "r1", call: "c2", failed: true, at: 3),
            SessionFile.assistant("a1", "r2", text: "好", at: 4))
        let tools = try #require(try index(f).messages.last?.tools)
        #expect(tools.commands == 1 && tools.failed == 1 && tools.items.map(\.failed) == [false, true])
    }

    @Test func aRoundWithoutToolsHasNoActivity() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(), SessionFile.user("u1", nil, "你好", at: 1), SessionFile.assistant("a1", "u1", text: "你好", at: 2))
        #expect(try index(f).messages.last?.tools == nil)
    }

    /// 清单最多 itemLimit 条、每条目标截到 targetLimit 个字符（同步体积）；计数不受清单截断影响。
    @Test func theListIsCappedAndEachTargetIsClipped() throws {
        var f = SessionFile(directory: dir)
        let many = (0..<45).map { Self.call("c\($0)", "read", ["path": "/work/x/file\($0).swift"]) }
        try f.append(
            SessionFile.header(cwd: "/work/x"), SessionFile.user("u1", nil, "全看一遍", at: 1), Self.calls("t1", "u1", many, at: 2),
            SessionFile.assistant("a1", "t1", text: "看完了", at: 3))
        let tools = try #require(try index(f).messages.last?.tools)
        #expect(tools.items.count == PiChatMessage.Tools.itemLimit && tools.reads == 45)

        var g = SessionFile(directory: dir, name: "long.jsonl")
        try g.append(
            SessionFile.header(cwd: "/work/x"), SessionFile.user("u1", nil, "跑", at: 1),
            Self.calls("t1", "u1", [Self.call("c1", "bash", ["command": String(repeating: "x", count: 400)])], at: 2),
            SessionFile.assistant("a1", "t1", text: "好", at: 3))
        let target = try #require(try index(g).messages.last?.tools?.items.first?.target)
        #expect(target == String(repeating: "x", count: PiChatMessage.Tools.targetLimit - 1) + "…")
    }

    /// 一轮跨几次读文件（在线会话每次追加都读一次）：调用在前一次、结果与回答在后一次，结果与一次读完一样；
    /// 只读摘要的首次读得到的检查点也与逐行全读一样（之后增量读接得上）。
    @Test func aRoundSplitAcrossReadsAndASummaryOnlyReadAgreeWithAFullRead() throws {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(cwd: "/work/x"), SessionFile.user("u1", nil, "跑一下", at: 1),
            Self.calls("t1", "u1", [Self.call("c1", "bash", ["command": "swift test"]), Self.call("c2", "read", ["path": "a.swift"])], at: 2))
        let first = try index(f)
        let summary = try PiHistory.index(file: f.url, from: nil, transcript: false)
        #expect(summary.checkpoint == first.checkpoint)

        try f.append(
            Self.result("r1", "t1", call: "c1", name: "bash", failed: true, at: 3), Self.result("r2", "r1", call: "c2", name: "read", at: 3))
        let midway = try index(f, from: first.checkpoint)
        #expect(try PiHistory.index(file: f.url, from: nil, transcript: false).checkpoint == midway.checkpoint)
        try f.append(SessionFile.assistant("a1", "r2", text: "测试没过", at: 4))
        let resumed = try index(f, from: midway.checkpoint)
        let whole = try index(f)

        #expect(resumed.messages.last?.tools == whole.messages.last?.tools)
        #expect(resumed.messages.last?.tools?.failed == 1 && resumed.messages.last?.tools?.reads == 1 && resumed.messages.last?.tools?.commands == 0)
        #expect(try PiHistory.index(file: f.url, from: summary.checkpoint).messages.last?.tools == whole.messages.last?.tools)
    }
}
#endif
