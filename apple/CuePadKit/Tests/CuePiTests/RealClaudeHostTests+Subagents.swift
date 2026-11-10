#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeHostTests {
    @Test func backgroundWorkKeepsTheSessionBusyUntilItsResultIsReportedBack() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            testbed.playBackgroundWork()
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.backgroundWork), to: id)
            try await testbed.finishBackgroundWork(id)
            try await testbed.expectSettledOnce(id, since: start, reply: "BG_DONE", roster: .done)
        }
    }

    @Test func aSubagentThatReportsEarlyAndRunsAgainSettlesTheSessionOnce() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            testbed.playEarlyReport()
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.earlyReport), to: id)
            try await testbed.finishEarlyReport(id)
            try await testbed.expectSettledOnce(id, since: start, reply: "NESTED_DONE", roster: .done, waits: 2)
        }
    }

    @Test func aStoppedSubagentSettlesTheSessionOnce() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            testbed.playLongSubagent()
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.longSubagent), to: id)
            try await eventually("等子代理") { testbed.bridge.session(id: id)?.state == .delegating }
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.stopSubagent), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "STOPPED", roster: .interrupted)
        }
    }
}
#endif
