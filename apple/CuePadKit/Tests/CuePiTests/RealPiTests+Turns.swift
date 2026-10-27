#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealPiTests {
    /// 正在等你确认时结束会话或停止这一轮：弹窗被取消（不取消 Pi 会一直等下去），会话不卡在等你。
    /// 结束走扩展接口 `ctx.shutdown`；测试驱动的是 RPC 进程，它在下一条命令后才检查退出请求，所以结束只验证弹窗被取消。
    @Test(arguments: ["end", "abort"]) func endingOrStoppingCancelsThePendingDialog(_ action: String) async throws {
        AgentTape.variant(action)
        try await withRig { pi, bridge, s in
            try pi.prompt("/ask")
            try await eventually("确认框") { bridge.sessions.first?.question?.kind == .known(.confirm) }

            let request = Task { action == "end" ? try await bridge.end(s.id) : try await bridge.abort(s.id) }
            defer { request.cancel() }

            _ = try await pi.waitForEvent("扩展拿到取消") { $0["method"] as? String == "notify" && $0["message"] as? String == "confirmed:false" }
            try await eventually("弹窗收起") { bridge.sessions.first?.question == nil }
        }
    }

    /// 停止这一轮：正在跑的一轮被中止、会话回到空闲等下一句（终态是"被中止"），会话还在、能接着说；空闲时停止直接成功、什么也不发生。
    @Test func abortStopsTheRunningTurnAndTheSessionTakesTheNextMessage() async throws {
        try await withRig { pi, bridge, s in
            try await bridge.abort(s.id)  // 空闲：成功，不改状态
            #expect(bridge.sessions.first?.state == .settled)

            try pi.prompt("[[slow]] 很长的一轮")
            try await eventually("在跑") { bridge.sessions.first?.state == .thinking }
            try await bridge.abort(s.id)
            try await eventually("回到等下一句") { bridge.sessions.first?.state == .settled }

            try pi.prompt("接着说")
            try await eventually("还能接着说") { recap(of: bridge.sessions.first)?.lastReply == "ECHO 接着说 IMAGES[]" }
        }
    }

    /// 工具跑着时停止，而 Pi 把这一轮记成了 error（工具被中止后的那次请求因中止失败，见 fake-model 的 [[abort-as-error]]）：
    /// 这一轮收到过停止，按被停下报，会话歇着、不显示出错；对话里是"已停止"，不是一轮出错的空回答。
    @Test func abortDuringAToolIsAStopEvenWhenPiRecordsAnError() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("[[tool:sleep 30]] [[abort-as-error]] 跑个慢命令")
            try await eventually("在跑工具") { bridge.sessions.first?.state == .tool }
            try await bridge.abort(s.id)
            try await eventually("这一轮结束") { [.settled, .error].contains(bridge.sessions.first?.state) }
            #expect(bridge.sessions.first?.state == .settled, "\(String(describing: bridge.sessions.first?.detail))")
            let messages = try PiHistory.index(file: #require(s.sessionFile), from: nil).messages
            #expect(messages.map(\.text) == ["[[tool:sleep 30]] [[abort-as-error]] 跑个慢命令", PiNotice.stopped.rawValue])
        }
    }

    @Test func sendDeliversTextAndImageIntoTheModelContext() async throws {
        try await withRig { _, bridge, s in
            try await bridge.send(PiMessage(text: "look", images: [PiImage(mimeType: "image/png", data: tinyPNG)]), to: s.id)
            try await eventually("回复写入") { !fileTexts("assistant", in: s.sessionFile).isEmpty }
            let prompt = try #require(fileMessages(in: s.sessionFile).first { $0.role == "user" })
            #expect(prompt.text.hasPrefix("look") && prompt.images == 1)
            let reply = fileTexts("assistant", in: s.sessionFile)[0]
            #expect(reply.contains("IMAGES[image/png:"), "假模型看到了图片：\(reply)")
        }
    }

    /// 会话正忙时发来的话先停下在跑的这一轮（连同跑着的工具），再作为新一轮开始；接连发两句，每句都是新的一轮——
    /// 前一句开的那一轮也被下一句停下，只有最后一句得到回答。每句都带着自己的投送请求 id。
    /// 前一句的那一轮停住（`[[slow]]`）：第二句到达时它不论已经开始还是还在等着，结果都一样。
    @Test func aMessageSentWhileBusyStopsTheRunningTurnAndStartsANewOneWithIt() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("[[tool:sleep 30]] 跑个慢命令")
            try await eventually("在跑工具") { bridge.sessions.first?.state == .tool }
            let first = UUID(), second = UUID(), log = ChangeLog(bridge)
            try await bridge.send(PiMessage(text: "[[slow]] FIRST", deliveryID: first.uuidString), to: s.id)
            try await bridge.send(PiMessage(text: "SECOND", deliveryID: second.uuidString), to: s.id)

            try await eventually("最后一句答完") {
                fileTexts("assistant", in: s.sessionFile).last?.hasPrefix("ECHO SECOND") == true && bridge.sessions.first?.state == .settled && log.states.last == .settled
            }
            #expect(log.settles == 1, "被停下的两轮都不算歇下：\(log.states)")
            let messages = try PiHistory.index(file: #require(s.sessionFile), from: nil).messages
            let users = messages.filter { $0.role == .known(.user) }
            #expect(users.map(\.text) == ["[[tool:sleep 30]] 跑个慢命令", "[[slow]] FIRST", "SECOND"])
            #expect(users.map(\.deliveryID) == [nil, first, second])
            #expect(!fileTexts("assistant", in: s.sessionFile).contains { $0 == "TOOL_DONE" || $0.contains("FIRST") }, "被停下的两轮都没有做完")
            // Pi 把这两轮记成 error（"The operation was aborted."）：对话里照停下处理，各留一行"已停止"
            #expect(messages.map(\.text).filter { $0 == PiNotice.stopped.rawValue }.count == 2, "\(messages.map(\.text))")
        }
    }

    /// 摘要（读会话文件）：你说的话单行、回答保留换行；块之间夹着真人文字的算你说的；超长截断。
    @Test func recapKeepsYourWordsOnOneLineAndTruncatesLongOnes() async throws {
        try await withRig { pi, _, s in
            try pi.prompt("第一行\n第二行")
            try await eventually("回答到了") { recap(of: s)?.lastReply == "ECHO 第一行\n第二行 IMAGES[]" }
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

    /// 上次在一轮中途退出（工具还在跑）的会话：摘要仍是之前那一轮做完的问答，不把半截的助手消息当成回答。
    @Test func anInterruptedRoundLeavesTheLastCompletedExchangeInTheRecap() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("第一问")
            try await eventually("第一轮做完") { recap(of: s)?.lastReply == "ECHO 第一问 IMAGES[]" }
            try pi.prompt("[[tool:sleep 30]]")
            try await eventually("工具在跑") {
                if case .tool = bridge.sessions.first?.state { true } else { false }
            }
            pi.kill(SIGKILL)
            try await eventually("会话结束") { bridge.sessions.isEmpty }

            let summary = try #require(recap(of: s))
            #expect(summary.lastPrompt == "第一问" && summary.lastReply == "ECHO 第一问 IMAGES[]")
        }
    }

    @Test func modelFailureShowsError() async throws {
        try await withRig { pi, bridge, _ in
            try pi.prompt("[[fail]]")
            try await eventually("error 状态") {
                bridge.sessions.first?.errorMessage?.contains("fake model failure") == true
            }
        }
    }
}
#endif
