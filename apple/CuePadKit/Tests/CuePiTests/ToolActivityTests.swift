#if os(macOS)
import Foundation
import Testing
import CueStore
@testable import CuePi

/// 会话文件按 Pi 真实写出的键序造（工具结果行：role、toolCallId、toolName、content、isError、timestamp）。
struct ToolActivityTests {
    let dir: URL
    init() throws { dir = try makeTempDirectory() }

    private static func call(_ id: String, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ["type": "toolCall", "id": id, "name": name, "arguments": arguments]
    }

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

        #expect(tools.steps == 8 && tools.steps == tools.items.count)
        #expect(tools.items.map(\.kind) == [.read, .read, .edit, .edit, .command, .command, .search, .other])
        #expect(tools.items.map(\.target) == ["Sources/a.swift", "Sources/b.swift", "Sources/a.swift", "NOTES.md", "swift test --filter Foo", "false", "TODO", "subagents"])
        #expect(tools.items.map(\.failed) == [false, false, false, false, false, true, false, false])
        #expect(tools.items[2].added == 2 && tools.items[2].removed == 1)
        #expect(tools.items[3].added == 3 && tools.items[3].removed == nil)
        #expect(tools.items[0].added == nil)
    }

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
        #expect(tools.steps == 2 && tools.items.map(\.failed) == [false, true])
    }
}
#endif
