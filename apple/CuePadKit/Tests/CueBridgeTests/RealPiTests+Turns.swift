#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

extension RealPiTests {
    /// 结束走扩展接口 `ctx.shutdown`；测试驱动的是 RPC 进程，它在下一条命令后才检查退出请求，所以结束只验证弹窗被取消。
    @Test(arguments: ["end", "abort"]) func endingOrStoppingCancelsThePendingDialog(_ action: String) async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("/ask")
            try await eventually("确认框") { bridge.sessions.first?.question?.kind == .known(.confirm) }

            let request = Task { action == "end" ? try await bridge.end(s.id) : try await bridge.abort(s.id) }
            defer { request.cancel() }

            _ = try await pi.waitForEvent("扩展拿到取消") { $0["method"] as? String == "notify" && $0["message"] as? String == "confirmed:false" }
            try await eventually("弹窗收起") { bridge.sessions.first?.question == nil }
        }
    }

    @Test func abortStopsTheRunningTurnAndTheSessionTakesTheNextMessage() async throws {
        try await withRig { pi, bridge, s in
            try await bridge.abort(s.id)  // 空闲：成功，不改状态
            #expect(bridge.sessions.first?.state == .settled)

            let gate = pi.hold("很长的一轮")
            try pi.prompt("很长的一轮")
            try await gate.reached()
            try await eventually("在跑") { bridge.sessions.first?.state == .thinking }
            try await bridge.abort(s.id)
            try await eventually("回到等下一句") { bridge.sessions.first?.state == .settled }

            try pi.prompt("接着说")
            try await eventually("还能接着说") { recap(of: bridge.sessions.first)?.lastReply == "ECHO 接着说" }
        }
    }

    /// 说到一半停住的回答（假模型的 `stream(_:until:)`）：说出的半句先作为草稿上报、这一轮还在跑，放行后同一条回答说完、这一轮做完
    @Test func aReplyHeldMidStreamShowsItsDraftAndFinishesOnceReleased() async throws {
        try await withRig { pi, bridge, s in
            let gate = pi.model.gate()
            pi.model.on("说一半", .stream(["前半句，", "后半句"], until: gate))
            try pi.prompt("说一半")
            try await gate.reached()
            try await eventually("半句是草稿，这一轮还在跑") {
                bridge.sessions.first?.state == .thinking && bridge.slots.first { $0.id == s.id }?.draft?.text == "前半句，后半句"
            }
            #expect(recap(of: bridge.sessions.first)?.lastReply == nil)

            gate.open()
            try await eventually("说完，这一轮做完") {
                bridge.sessions.first?.state == .settled && recap(of: bridge.sessions.first)?.lastReply == "前半句，后半句"
            }
        }
    }

    @Test func abortDuringAToolIsAStop() async throws {
        try await withRig { pi, bridge, s in
            pi.model.on("跑个慢命令", .call("bash", ["command": "sleep 30"]), .say("TOOL_DONE"))
            try pi.prompt("跑个慢命令")
            try await eventually("在跑工具") { bridge.sessions.first?.state == .tool }
            try await bridge.abort(s.id)
            try await eventually("这一轮结束") { [.settled, .error].contains(bridge.sessions.first?.state) }
            #expect(bridge.sessions.first?.state == .settled, "\(String(describing: bridge.sessions.first?.detail))")
            let messages = try History.index(file: #require(s.sessionFile), from: nil).messages
            #expect(messages.map(\.text) == ["跑个慢命令", ChatNotice.stopped.rawValue])
        }
    }

    @Test func sendDeliversTextAndImageIntoTheModelContext() async throws {
        try await withRig { _, bridge, s in
            try await bridge.send(SessionMessage(text: "look", images: [MessageImage(mimeType: "image/png", data: tinyPNG)]), to: s.id)
            try await eventually("回复写入") { !fileTexts("assistant", in: s.sessionFile).isEmpty }
            let prompt = try #require(fileMessages(in: s.sessionFile).first { $0.role == "user" })
            #expect(prompt.text.hasPrefix("look") && prompt.images == 1)
            let reply = fileTexts("assistant", in: s.sessionFile)[0]
            #expect(reply.contains("IMAGES[image/png:"), "假模型看到了图片：\(reply)")
        }
    }

    /// 前一句的那一轮停在假模型里：第二句到达时它不论已经开始还是还在等着，结果都一样。
    @Test func aMessageSentWhileBusyStopsTheRunningTurnAndStartsANewOneWithIt() async throws {
        try await withRig { pi, bridge, s in
            pi.model.on("跑个慢命令", .call("bash", ["command": "sleep 30"]), .say("TOOL_DONE"))
            _ = pi.hold("FIRST")
            try pi.prompt("跑个慢命令")
            try await eventually("在跑工具") { bridge.sessions.first?.state == .tool }
            let first = UUID(), second = UUID(), log = ChangeLog(bridge)
            try await bridge.send(SessionMessage(text: "FIRST", deliveryID: first.uuidString), to: s.id)
            try await bridge.send(SessionMessage(text: "SECOND", deliveryID: second.uuidString), to: s.id)

            try await eventually("最后一句答完") {
                fileTexts("assistant", in: s.sessionFile).last?.hasPrefix("ECHO SECOND") == true && bridge.sessions.first?.state == .settled && log.states.last == .settled
            }
            #expect(log.settles == 1, "被停下的两轮都不算歇下：\(log.states)")
            let messages = try History.index(file: #require(s.sessionFile), from: nil).messages
            let users = messages.filter { $0.role == .known(.user) }
            #expect(users.map(\.text) == ["跑个慢命令", "FIRST", "SECOND"])
            #expect(users.map(\.deliveryID) == [nil, first, second])
            #expect(!fileTexts("assistant", in: s.sessionFile).contains { $0 == "TOOL_DONE" || $0.contains("FIRST") }, "被停下的两轮都没有做完")
            // Pi 把这两轮记成 error（"The operation was aborted."）：对话里照停下处理，各留一行"已停止"
            #expect(messages.map(\.text).filter { $0 == ChatNotice.stopped.rawValue }.count == 2, "\(messages.map(\.text))")
        }
    }

    @Test func recapKeepsYourWordsOnOneLineAndTruncatesLongOnes() async throws {
        try await withRig { pi, _, s in
            try pi.prompt("第一行\n第二行")
            try await eventually("回答到了") { recap(of: s)?.lastReply == "ECHO 第一行\n第二行" }
            #expect(recap(of: s)?.lastPrompt == "第一行 第二行")

            // 块与块之间夹着真人文字不是机器消息（整条都是块的见 `RealTranscriptTests`）
            let mixed = "<some_event>\n机器一\n</some_event>\n请解释这个结果\n<some_event>\n机器二\n</some_event>"
            try pi.prompt(mixed)
            try await eventually("夹着真人文字的那轮回答") { recap(of: s)?.lastReply?.contains("请解释这个结果") == true }
            #expect(recap(of: s)?.lastPrompt?.contains("请解释这个结果") == true)

            let long = String(repeating: "长", count: 1300)
            try pi.prompt(long)
            try await eventually("长回答截断") { recap(of: s)?.lastReply?.hasPrefix("ECHO 长") == true }
            let summary = try #require(recap(of: s))
            #expect(summary.lastPrompt?.count == 500 && summary.lastPrompt?.hasSuffix("…") == true)
            #expect(summary.lastReply?.count == 1200 && summary.lastReply?.hasSuffix("…") == true)
        }
    }

    @Test func anInterruptedRoundLeavesTheLastCompletedExchangeInTheRecap() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("第一问")
            try await eventually("第一轮做完") { recap(of: s)?.lastReply == "ECHO 第一问" }
            pi.model.on("慢命令", .call("bash", ["command": "sleep 30"]))
            try pi.prompt("慢命令")
            try await eventually("工具在跑") {
                if case .tool = bridge.sessions.first?.state { true } else { false }
            }
            pi.kill(SIGKILL)
            try await eventually("会话结束") { bridge.sessions.isEmpty }

            let summary = try #require(recap(of: s))
            #expect(summary.lastPrompt == "第一问" && summary.lastReply == "ECHO 第一问")
        }
    }

    @Test func retryRerunsTheFailedTurnAndTheConversationOnlyGainsTheNewAnswer() async throws {
        try await withRig { pi, bridge, s in
            let file = try #require(s.sessionFile)
            let prompt = "跑一遍"
            pi.model.on(prompt, times: 1, .fail("fake model failure"))
            try pi.prompt(prompt)
            try await eventually("出错") { bridge.sessions.first?.state == .error }
            #expect(try History.index(file: file, from: nil).messages.map(\.text) == [prompt])

            try await bridge.retry(s.id)
            try await eventually("重跑做完") { recap(of: bridge.sessions.first)?.lastReply == "ECHO 跑一遍" }
            try await eventually("歇下") { bridge.sessions.first?.state == .settled }
            #expect(try History.index(file: file, from: nil).messages.map(\.text) == [prompt, "ECHO 跑一遍"])
            #expect(pi.model.requests.last?.messages.map(\.role) == [.user], "重跑的请求里没有出错的那一轮")

            try pi.prompt("再来")
            try await eventually("下一句") { recap(of: bridge.sessions.first)?.lastReply == "ECHO 再来" }
            #expect(pi.model.requests.last?.messages.map(\.role) == [.user, .assistant, .user])
            await #expect(throws: BridgeError.rejected("nothing_to_retry")) { try await bridge.retry(s.id) }
        }
    }

    @Test func modelFailureShowsError() async throws {
        try await withRig { pi, bridge, _ in
            pi.model.on("出错吧", .fail("fake model failure"))
            try pi.prompt("出错吧")
            try await eventually("error 状态") {
                bridge.sessions.first?.errorMessage?.contains("fake model failure") == true
            }
        }
    }
}
#endif
