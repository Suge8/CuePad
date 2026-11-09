#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeTerminalTests {
    /// 先于 CuePad 开着、CuePad 起来后还没跑过钩子的会话：CuePad 从会话列表补上它，只拿到收件箱，没有令牌（它只在钩子的环境里）。
    /// 跳过权限确认的会话把没带令牌的话扣在终端里等批准（"Held message from another session"），所以 CuePad 不发、说没发出；
    /// 在终端里说一句话（跑了钩子、带来令牌）之后照常送到。跳过权限确认来自命令行，或命令行没指定模式时来自设置里的默认模式。
    @Test(arguments: [false, true]) func aBypassSessionIsRefusedUntilAHookBringsItsInboxToken(fromSettings: Bool) async throws {
        let defaultMode = fromSettings ? #", "permissions": {"defaultMode": "bypassPermissions"}"# : ""
        try await ClaudeTestbed.run(settings: #"{"skipDangerousModePermissionPrompt": true\#(defaultMode)}"#) { testbed in
            let terminal = try await testbed.terminal(mode: fromSettings ? nil : "bypassPermissions")
            let registry = testbed.config.appending(path: "sessions/\(terminal.pid).json")
            if fromSettings {
                // 设置里默认跳过权限确认时它先问要不要改成默认 auto：留在跳过权限确认
                let dialog = "Make auto mode your default permission mode?"
                try await testbed.waitOnScreen("问要不要改成 auto", on: terminal, in: "") { await terminal.screen.contains(dialog) }
                try await terminal.keys("Down")
                try await terminal.press("Enter", on: dialog) { await !terminal.screen.contains(dialog) }
            }
            try await testbed.waitOnScreen("跳过权限确认、歇着（CuePad 起来之前）", on: terminal, in: "") {
                await terminal.screen.contains("bypass permissions on")
                    && (try? Data(contentsOf: registry)).flatMap(JSONValue.parse)?["status"]?.string == "idle"
            }
            try testbed.startConnected()
            let session = try await testbed.waitForSession(pid: terminal.pid)

            await #expect(throws: PiBridgeError.rejected("unattested")) {
                try await testbed.bridge.send(PiMessage(text: "INBOX-PROBE 只回复 OK"), to: session.id)
            }
            #expect(await !terminal.screen.contains("Held"))

            testbed.on("只回复 OK", .say("OK"))
            let typed = Date()
            try await terminal.type("TERMINAL-TURN 只回复 OK")
            try await testbed.waitForTurn(session.id, since: typed)
            let delivery = UUID()
            try await testbed.bridge.send(PiMessage(text: "INBOX-PROBE 只回复 OK", deliveryID: delivery.uuidString), to: session.id)
            try await testbed.waitOnScreen("话送到了", on: terminal, in: session.id) {
                (try? testbed.transcript(session.sessionFile).messages.contains { $0.deliveryID == delivery }) == true
            }
            #expect(await !terminal.screen.contains("Held"))
        }
    }
}
#endif
