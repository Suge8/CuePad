#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeHostTests {
    /// #58：没登录的托管 Claude Code 也先报收下（`command_lifecycle` 的 started）再取消：自定义命令与说的话都以它的原话报没送达，
    /// 不报已送达；不用模型的本地命令（改名）照常做完、报已送达。
    @Test func aSignedOutHostedSessionRefusesWithItsOwnReason() async throws {
        try await ClaudeTestbed.run(signedIn: false) { testbed in
            let commands = testbed.work.appending(path: ".claude/commands", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
            try "---\ndescription: Say hello\n---\nReply with exactly HELLO.\n".write(to: commands.appending(path: "hello.md"), atomically: true, encoding: .utf8)
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            #expect(testbed.bridge.session(id: id)?.commands.contains { $0.name == "hello" } == true)
            let notLoggedIn = PiBridgeError.refused("Not logged in · Please run /login")

            try await testbed.bridge.command("/rename 未登录也能改名", deliveryID: UUID().uuidString, in: id)
            #expect(testbed.bridge.session(id: id)?.displayName == "未登录也能改名")
            await #expect(throws: notLoggedIn) { try await testbed.bridge.command("/hello", deliveryID: UUID().uuidString, in: id) }
            await #expect(throws: notLoggedIn) { try await testbed.bridge.send(PiMessage(text: "只回复 OK", deliveryID: UUID().uuidString), to: id) }
        }
    }
}
#endif
