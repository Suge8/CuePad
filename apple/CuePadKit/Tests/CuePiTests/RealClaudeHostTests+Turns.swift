#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeHostTests {
    /// 停在流式回答中途：假模型的请求停在闸门上，停下后它被断开（闸门上不再有等的），之后的话照常回答。
    @Test func stoppingAnAnswerInProgressLetsTheNextMessageThrough() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let gate = testbed.model.gate()
            testbed.on("茶叶史", .held(gate, then: .say("LATE")))
            testbed.on("只回复 AFTER", .say("AFTER"))

            let writing = Task { try await testbed.bridge.send(PiMessage(text: "写一篇两千字的茶叶史"), to: id) }
            try await gate.reached()
            try await eventually("在跑") { testbed.bridge.session(id: id)?.state.isWorking == true }
            try await testbed.bridge.abort(id)
            try await eventually("停下") { testbed.bridge.session(id: id)?.state == .settled }
            try await writing.value
            try await eventually("假模型被断开") { gate.waiting == 0 }

            let after = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id, since: after)
            try await testbed.waitForDraftLanded(id)
            let said = try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).messages
            #expect(said.last?.text == "AFTER" && !said.contains { $0.text.contains("LATE") }, "\(said.map(\.text))")
        }
    }

    /// 说到一半停住的回答（假模型的 `stream(_:until:)`，Anthropic Messages）：这一轮还在跑、回答没落盘，放行后同一条回答说完、这一轮歇下
    @Test func aReplyHeldMidStreamFinishesOnceReleased() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let gate = testbed.model.gate()
            testbed.on("说一半", .stream(["前半句，", "后半句"], until: gate))

            let after = Date()
            let sending = Task { try await testbed.bridge.send(PiMessage(text: "说一半"), to: id) }
            try await gate.reached()
            try await eventually("在跑") { testbed.bridge.session(id: id)?.state.isWorking == true }
            // 会话文件这时可能还没写出来
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
            let never = testbed.work.appending(path: "never.txt")
            let command = #"python3 -c "import time; time.sleep(100)" && touch \#(never.path)"#
            testbed.on("SLEEP") { $0.step == 0 ? .call("Bash", ["command": command, "description": "slow"]) : .say("SLEPT") }
            testbed.on("只回复 AFTER", .say("AFTER"))

            try await testbed.bridge.send(PiMessage(text: "SLEEP now"), to: id)
            try await eventually("在跑命令") { testbed.bridge.session(id: id)?.state == .tool }
            try await testbed.bridge.abort(id)
            try await eventually("停下") { testbed.bridge.session(id: id)?.state == .settled }

            let after = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id, since: after)
            try await testbed.waitForDraftLanded(id)
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply == "AFTER")
            #expect(!FileManager.default.fileExists(atPath: never.path))
        }
    }

    /// 命令比等的时限长：没被打断就等不到这句的回答。
    @Test(arguments: [false, true]) func aMessageWhileBusyStopsTheTurnAndStartsANewOne(toolRunning: Bool) async throws {
        try await ClaudeTestbed.run(settings: toolRunning ? #"{"permissions": {"allow": ["Bash"]}}"# : #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let never = testbed.work.appending(path: "never.txt")
            let command = toolRunning ? #"python3 -c "import time; time.sleep(100)" && touch \#(never.path)"# : "touch \(never.path)"
            testbed.on("ZEBRA") { $0.step == 0 ? .call("Bash", ["command": command, "description": "zebra"]) : .say("ZEBRA") }
            testbed.on("只回复 MANGO", .say("MANGO"))

            try await testbed.bridge.send(PiMessage(text: "ZEBRA go"), to: id)
            if toolRunning {
                try await eventually("在跑命令") { testbed.bridge.session(id: id)?.detail?.contains("time.sleep(100)") == true }
            } else {
                _ = try await testbed.waitForQuestion(id)
            }
            let delivery = UUID().uuidString
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 MANGO", deliveryID: delivery), to: id)
            try await testbed.waitForTurn(id, since: asked)
            try await testbed.waitForDraftLanded(id)

            let session = try #require(testbed.bridge.session(id: id))
            #expect(session.state == .settled && session.question == nil)
            #expect(!FileManager.default.fileExists(atPath: never.path))
            let said = try testbed.transcript(session.sessionFile).messages
            let mango = try #require(said.firstIndex { $0.deliveryID == UUID(uuidString: delivery) })
            #expect(said[..<mango].contains { $0.text == PiNotice.stopped.rawValue }, "\(said.map(\.text))")
            #expect(said.last?.text.contains("MANGO") == true, "\(said.map(\.text))")
        }
    }
}
#endif
