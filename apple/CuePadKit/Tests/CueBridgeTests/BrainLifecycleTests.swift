#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

@MainActor
@Suite
struct BrainLifecycleTests {
    private func fakeRuntime(_ runtime: AgentKind, _ body: String, timing: Timing) throws -> (CueBrainConfig, pid: URL) {
        let directory = try makeTempDirectory()
        let script = directory.appending(path: "fake-\(runtime.rawValue)")
        try TestScript.install("#!/bin/sh\necho $$ > \"$PID_FILE\"\n\(body)\n", at: script)
        let pid = directory.appending(path: "pid")
        let config = CueBrainConfig(
            runtime: runtime, executable: script, model: nil, effort: nil, systemPrompt: "x", workingDirectory: directory, mcp: ["/usr/bin/true"],
            environment: ["PID_FILE": pid.path], timing: timing)
        return (config, pid)
    }

    private func pid(in file: URL) throws -> pid_t {
        try #require(pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func aRuntimeThatRejectsTheHandshakeIsNotLeftRunning() async throws {
        let clock = ManualTiming()
        let (config, file) = try fakeRuntime(.codex, #"""
            trap '' TERM
            read line
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            printf '{"id":%s,"error":{"code":-1,"message":"nope"}}\n' "$id"
            exec sleep 300
            """#, timing: clock.timing)
        let start = Task { _ = try await config.startBrain() }
        try await clock.waitForSleeper()
        clock.advance(AgentTimeouts.endGrace)
        await #expect(throws: CodexRPCError.server(code: -1, message: "nope")) { try await start.value }
        #expect(kill(try pid(in: file), 0) != 0)
    }

    @Test func stopEndsARuntimeThatIgnoresEOFAndSIGTERM() async throws {
        let clock = ManualTiming()
        let (config, file) = try fakeRuntime(.claudeCode, #"""
            trap '' TERM
            read line
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"mcpServers":[{"name":"cuepad","status":"connected"}]}}}\n' "$id"
            exec sleep 300
            """#, timing: clock.timing)
        let brain = try await config.startBrain()
        let stopped = Task { await brain.stop()() }
        for _ in 0..<2 {
            try await clock.waitForSleeper()
            clock.advance(AgentTimeouts.endGrace)
        }
        await stopped.value
        #expect(kill(try pid(in: file), 0) != 0)
        var last: TurnEvent?
        for await event in brain.events { last = event }
        #expect(last == .exited(nil))
    }

    @Test func cancellingAGrokStartWaitingForMCPReturnsPromptly() async throws {
        let (config, _) = try fakeRuntime(.grok, #"""
            while read line; do
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id"
              case "$line" in *session/new*) touch "$PID_FILE.opened" ;; esac
            done
            """#, timing: ManualTiming().timing)
        let opened = URL(filePath: config.environment["PID_FILE"]! + ".opened")
        let start = Task { _ = try await config.startBrain() }
        try await eventually("session/new 已答") { FileManager.default.fileExists(atPath: opened.path) }
        try await Task.sleep(for: .milliseconds(200))
        start.cancel()
        let (outcomes, first) = AsyncStream.makeStream(of: Bool.self)
        let waiter = Task { _ = await start.result; first.yield(true) }
        let timer = Task { try? await Task.sleep(for: .seconds(5)); first.yield(false) }
        defer { waiter.cancel(); timer.cancel() }
        var returned = false
        for await done in outcomes { returned = done; break }
        #expect(returned)
    }
}
#endif
