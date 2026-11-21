#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CueBridge

extension RealClaudeHostTests {
    @Test func stoppingAnAnswerInProgressLetsTheNextMessageThrough() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let gate = testbed.model.gate()
            testbed.on("茶叶史", .held(gate, then: .say("LATE")))
            testbed.on("只回复 AFTER", .say("AFTER"))

            let writing = Task { try await testbed.bridge.send(SessionMessage(text: "写一篇两千字的茶叶史"), to: id) }
            try await gate.reached()
            try await eventually("在跑") { testbed.bridge.session(id: id)?.state.isWorking == true }
            try await testbed.bridge.abort(id)
            try await eventually("停下") { testbed.bridge.session(id: id)?.state == .settled }
            try await writing.value
            try await eventually("假模型被断开") { gate.waiting == 0 }

            let after = Date()
            try await testbed.bridge.send(SessionMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id, since: after)
            try await testbed.waitForDraftLanded(id)
            let said = try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).messages
            #expect(said.last?.text == "AFTER" && !said.contains { $0.text.contains("LATE") }, "\(said.map(\.text))")
        }
    }

    @Test func aReplyHeldMidStreamFinishesOnceReleased() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let gate = testbed.model.gate()
            testbed.on("说一半", .stream(["前半句，", "后半句"], until: gate))

            let after = Date()
            let sending = Task { try await testbed.bridge.send(SessionMessage(text: "说一半"), to: id) }
            try await gate.reached()
            try await eventually("在跑") { testbed.bridge.session(id: id)?.state.isWorking == true }
            #expect((try? testbed.transcript(testbed.bridge.session(id: id)?.sessionFile))?.recap.lastReply == nil)

            gate.open()
            try await sending.value
            try await testbed.waitForTurn(id, since: after)
            try await testbed.waitForDraftLanded(id)
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply == "前半句，后半句")
            #expect(testbed.bridge.session(id: id)?.state == .settled)
        }
    }

    @Test func stoppingARunningToolEndsItsCommand() async throws {
        try await ClaudeTestbed.run(settings: #"{"permissions": {"allow": ["Bash"]}}"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let never = testbed.work.appending(path: "never.txt"), pidFile = testbed.work.appending(path: "tool.pid")
            testbed.on("SLEEP") { $0.step == 0 ? .call("Bash", ["command": slowTool(pidFile, never), "description": "slow"]) : .say("SLEPT") }
            testbed.on("只回复 AFTER", .say("AFTER"))

            try await testbed.bridge.send(SessionMessage(text: "SLEEP now"), to: id)
            try await eventually("在跑命令") { testbed.bridge.session(id: id)?.state == .tool && toolPid(pidFile) != nil }
            try await testbed.bridge.abort(id)
            try await eventually("停下") { testbed.bridge.session(id: id)?.state == .settled }
            try await eventually("命令的进程退了") { kill(toolPid(pidFile)!, 0) != 0 }

            let after = Date()
            try await testbed.bridge.send(SessionMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id, since: after)
            try await testbed.waitForDraftLanded(id)
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply == "AFTER")
            #expect(!FileManager.default.fileExists(atPath: never.path))
        }
    }

    @Test(arguments: [false, true]) func aMessageWhileBusyStopsTheTurnAndStartsANewOne(toolRunning: Bool) async throws {
        try await ClaudeTestbed.run(settings: toolRunning ? #"{"permissions": {"allow": ["Bash"]}}"# : #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let never = testbed.work.appending(path: "never.txt"), pidFile = testbed.work.appending(path: "tool.pid")
            let command = toolRunning ? slowTool(pidFile, never) : "touch \(never.path)"
            testbed.on("ZEBRA") { $0.step == 0 ? .call("Bash", ["command": command, "description": "zebra"]) : .say("ZEBRA") }
            testbed.on("只回复 MANGO", .say("MANGO"))

            try await testbed.bridge.send(SessionMessage(text: "ZEBRA go"), to: id)
            if toolRunning {
                try await eventually("在跑命令") { testbed.bridge.session(id: id)?.detail?.contains("time.sleep(100") == true && toolPid(pidFile) != nil }
            } else {
                _ = try await testbed.waitForQuestion(id)
            }
            let delivery = UUID().uuidString
            let asked = Date()
            try await testbed.bridge.send(SessionMessage(text: "只回复 MANGO", deliveryID: delivery), to: id)
            try await testbed.waitForTurn(id, since: asked)
            try await testbed.waitForDraftLanded(id)

            if toolRunning { try await eventually("命令的进程退了") { kill(toolPid(pidFile)!, 0) != 0 } }
            let session = try #require(testbed.bridge.session(id: id))
            #expect(session.state == .settled && session.question == nil)
            #expect(!FileManager.default.fileExists(atPath: never.path))
            let said = try testbed.transcript(session.sessionFile).messages
            let mango = try #require(said.firstIndex { $0.deliveryID == UUID(uuidString: delivery) })
            #expect(said[..<mango].contains { $0.text == ChatNotice.stopped.rawValue }, "\(said.map(\.text))")
            #expect(said.last?.text.contains("MANGO") == true, "\(said.map(\.text))")
        }
    }
}

private func slowTool(_ pidFile: URL, _ never: URL) -> String {
    #"python3 -c "import os, time; time.sleep(100 + 0 * open('\#(pidFile.path)', 'w').write(str(os.getpid())))" && touch \#(never.path)"#
}

private func toolPid(_ pidFile: URL) -> pid_t? { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) } }
#endif
