#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

extension RealPiTests {
    /// 等待用户时 `question` 是弹窗：种类、文案（确认框的标题与说明，换行分隔）、选项与这次弹窗的标识；在 Pi 里回答后清空。
    @Test func extensionDialogShowsWaitingUserWithTheQuestionThenResumes() async throws {
        try await withRig { pi, bridge, _ in
            try pi.prompt("/ask")
            try await eventually("等待用户") {
                bridge.sessions.first?.state == .waitingForUser && bridge.sessions.first?.detail == "Proceed?"
            }
            let confirm = try #require(bridge.sessions.first?.question)
            #expect(confirm.kind == .known(.confirm) && confirm.text == "Proceed?\ntest dialog" && confirm.options.isEmpty && confirm.promptID != nil)
            let dialog = try await pi.waitForEvent("对话框请求") { $0["method"] as? String == "confirm" }
            try pi.send(["type": "extension_ui_response", "id": dialog["id"] as Any, "confirmed": true])
            try await eventually("回到空闲") { bridge.sessions.first?.state == .settled }
            #expect(bridge.sessions.first?.question == nil)

            try pi.prompt("/pick")
            try await eventually("选择框的问题带选项") { bridge.sessions.first?.question?.options == ["Alpha", "Beta"] }
            #expect(bridge.sessions.first?.question?.kind == .known(.select) && bridge.sessions.first?.question?.text == "Which one?")
            let select = try await pi.waitForEvent("选择框请求") { $0["method"] as? String == "select" }
            try pi.send(["type": "extension_ui_response", "id": select["id"] as Any, "value": "Alpha"])
            try await eventually("回答后清空") { bridge.sessions.first?.question == nil }
        }
    }

    /// 从 CuePad 作答：选择框选中第二项、确认框答"是"，Pi 那边的调用拿到这个答案，弹窗收起、问题清空。
    @Test func answeringThroughTheBridgeResolvesThePiDialog() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("/pick")
            try await eventually("选择框") { bridge.sessions.first?.question?.options == ["Alpha", "Beta"] }
            let pick = try #require(bridge.sessions.first?.question?.promptID)
            try await bridge.answer(.option("Beta"), to: pick, in: s.id)
            _ = try await pi.waitForEvent("扩展拿到选中的第二项") { $0["method"] as? String == "notify" && $0["message"] as? String == "picked:Beta" }
            try await eventually("问题清空") { bridge.sessions.first?.question == nil }

            try pi.prompt("/ask")
            try await eventually("确认框") { bridge.sessions.first?.question?.kind == .known(.confirm) }
            let ask = try #require(bridge.sessions.first?.question?.promptID)
            try await bridge.answer(.confirmed(true), to: ask, in: s.id)
            _ = try await pi.waitForEvent("扩展拿到确认") { $0["method"] as? String == "notify" && $0["message"] as? String == "confirmed:true" }
            try await eventually("问题清空") { bridge.sessions.first?.question == nil }
        }
    }

    @Test func answeringAStalePromptIsRejected() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("/pick")
            try await eventually("选择框") { bridge.sessions.first?.question?.promptID != nil }
            let first = try #require(bridge.sessions.first?.question?.promptID)
            try await bridge.answer(.option("Alpha"), to: first, in: s.id)
            try await eventually("问题清空") { bridge.sessions.first?.question == nil }
            await #expect(throws: PiBridgeError.rejected("no_prompt")) { try await bridge.answer(.option("Alpha"), to: first, in: s.id) }

            try pi.prompt("/pick")
            try await eventually("新的选择框") { bridge.sessions.first?.question?.promptID.map { $0 != first } == true }
            await #expect(throws: PiBridgeError.rejected("stale_prompt")) { try await bridge.answer(.option("Alpha"), to: first, in: s.id) }
            let current = try #require(bridge.sessions.first?.question?.promptID)
            await #expect(throws: PiBridgeError.rejected("bad_answer")) { try await bridge.answer(.option("Gamma"), to: current, in: s.id) }
        }
    }
}
#endif
