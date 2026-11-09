#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 列表请求途中可能换轮或收尾：外壳把列表扣住，期间写好会话文件，再交出"在跑"。不起 Claude Code（录像带是空的）。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.timeLimit(.minutes(5)))
struct ClaudeDiscoveryTests {
    @Test func aRoundThatChangesOrEndsWhileCuePadIsListingItIsReadFromTheSessionFile() async throws {
        let wrapper = #"if [ "$1" = agents ]; then touch "${0%/*}/listed"; cat "${0%/*}/release" >/dev/null; cat "${0%/*}/listing.json"; else "$REAL" "$@"; fi"#
        try await ClaudeTestbed.run(installHooks: false, wrapper: wrapper) { testbed in
            let gate = testbed.wrapperDirectory
            let release = gate.appending(path: "release"), listing = gate.appending(path: "listing.json")
            #expect(mkfifo(release.path, 0o600) == 0)
            try testbed.startConnected()
            let listed = gate.appending(path: "listed")
            try await eventually("列表请求发出") { FileManager.default.fileExists(atPath: listed.path) }
            // 都写在列表请求发出之后，相隔 1 毫秒（会话文件的时间戳精确到毫秒）
            let base = try #require(try FileManager.default.attributesOfItem(atPath: listed.path)[.modificationDate] as? Date)
            let at = { (step: Double) in base + step / 1000 }
            let ended = try Transcript(testbed, id: UUID().uuidString.lowercased())
            try ended.user("go", at: at(1))
            try await testbed.index(ended.url)
            try ended.reply("DONE", at: at(2))
            let changed = try Transcript(testbed, id: UUID().uuidString.lowercased())
            try changed.user("first", at: at(3))
            try changed.reply("ONE", at: at(4))
            try await testbed.index(changed.url)
            try changed.user("second", at: at(5))
            // 列表里的进程要活着：起一个读标准输入的进程顶替 Claude Code，关掉输入它就退出（测试台停时等它退出）
            let stand = Process(), input = Pipe()
            stand.executableURL = URL(filePath: "/bin/cat")
            stand.standardInput = input
            try stand.run()
            defer { try? input.fileHandleForWriting.close() }
            let pid = stand.processIdentifier
            let entries: JSONValue = .array([changed, ended].map { ["pid": .number(Double(pid)), "sessionId": .string($0.id), "cwd": .string(testbed.work.path), "status": "busy"] })
            try entries.data.write(to: listing)
            close(open(release.path, O_WRONLY))

            try await eventually("两个会话接上") { testbed.bridge.sessions.count == 2 }
            let first = try #require(testbed.bridge.sessions.first { $0.sessionID == changed.id })
            let turn = try #require(first.turnStartedAt)
            let before = try testbed.transcript(first.sessionFile).recap
            #expect(before.lastReply == "ONE")
            #expect(try #require(before.answeredAt) < turn)
            try changed.reply("TWO", at: .now)
            let after = try testbed.transcript(first.sessionFile).recap
            #expect(after.lastReply == "TWO")
            #expect(try #require(after.answeredAt) >= turn)

            let second = try #require(testbed.bridge.sessions.first { $0.sessionID == ended.id })
            let recap = try testbed.transcript(second.sessionFile).recap
            #expect(recap.lastReply == "DONE")
            #expect(try #require(recap.answeredAt) >= #require(second.turnStartedAt))
        }
    }

    private struct Transcript {
        let id: String
        let url: URL

        init(_ testbed: ClaudeTestbed, id: String) throws {
            self.id = id
            url = ClaudeCode.sessionFile(home: testbed.config, cwd: testbed.work, sessionID: id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }

        func user(_ text: String, at time: Date) throws {
            try write(["type": "user", "message": ["role": "user", "content": .string(text)]], at: time)
        }

        func reply(_ text: String, at time: Date) throws {
            let message: JSONValue = ["role": "assistant", "model": "claude-test", "stop_reason": "end_turn", "content": [["type": "text", "text": .string(text)]]]
            try write(["type": "assistant", "message": message], at: time)
        }

        private func write(_ line: JSONValue, at time: Date) throws {
            guard case .object(var fields) = line else { return }
            fields["uuid"] = .string(UUID().uuidString)
            fields["sessionId"] = .string(id)
            fields["timestamp"] = .string(time.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONValue.object(fields).data + Data("\n".utf8))
        }
    }
}
#endif
