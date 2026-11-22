#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

@MainActor
@Suite(RealAgents.tiered, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedTurnTests {
    @Test(arguments: Hosting.allCases)
    func aMessageDuringATurnStartsTheNextWithoutSettlingBetween(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: .system) { rig in
            rig.hang("BUSY-HANG")
            let id = try await rig.open()
            try await rig.bridge.send(SessionMessage(text: "BUSY-HANG first"), to: id)
            try await eventually("这一轮在跑、停在模型里") { rig.asked("BUSY-HANG first") && rig.bridge.session(id: id)?.state.isWorking == true }
            let log = ChangeLog(rig.bridge)
            _ = try await rig.converse("NEXT", in: id)
            try await eventually("这句答完歇下") { log.settles > 0 && rig.bridge.session(id: id)?.state == .settled }
            #expect(log.settles == 1, "\(log.states)")
        }
    }

    /// 允许与拒绝都从 CuePad 答：答之前命令不跑，允许才跑（文件在不在），这一轮做完、之后照常说话。
    /// 拒绝之后各家不同：Claude Code 把拒绝当工具结果交给模型、这一轮接着答；Grok 不再请求模型、这一轮就此收尾。
    /// Codex 托管时不审批（`approval_policy` 照用户的），dsh 不发权限请求（它的提问见下一例）。
    @Test(arguments: [(Hosting.claude, true), (.claude, false), (.grok, true), (.grok, false)])
    func aPermissionIsAnsweredFromCuePad(_ hosting: Hosting, allow: Bool) async throws {
        try await EndRig.run(hosting, timing: .system, settings: #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { rig in
            let touched = rig.work.appending(path: "hosted.txt")
            // Grok 对工作目录外的绝对路径不问（原用例的写法），Claude Code 按上面那条规则问
            let (tool, command) = hosting == .claude ? ("Bash", "touch \(touched.path)") : ("run_terminal_command", "echo ok > hosted.txt")
            rig.model.on("TOUCH") { $0.step == 0 ? .call(tool, ["command": command, "description": "touch"]) : .say("DONE") }
            let id = try await rig.open()

            try await rig.bridge.send(SessionMessage(text: "TOUCH it"), to: id)
            try await eventually("等你确认") { rig.bridge.session(id: id)?.question != nil }
            let permission = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(permission.kind == .known(.confirm) && permission.text.contains(command), "\(permission.text)")
            if hosting == .claude { #expect(permission.text.hasPrefix("允许 Claude Code 使用 Bash？"), "\(permission.text)") }
            #expect(!FileManager.default.fileExists(atPath: touched.path), "没答之前不跑")
            try await rig.bridge.answer(.confirmed(allow), to: try #require(permission.promptID), in: id)

            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled }
            #expect(FileManager.default.fileExists(atPath: touched.path) == allow)
            #expect(rig.bridge.session(id: id)?.question == nil)
            let followUps = rig.model.requests.filter { $0.prompt.contains("TOUCH") && $0.step == 1 }
            let session = try #require(rig.bridge.session(id: id))
            if allow || hosting == .claude {
                let result = try #require(followUps.last?.results.last)
                #expect(result.contains("拒绝了") == !allow, "工具结果：\(result)")
                if hosting == .grok { #expect(result.contains("exit: 0"), "工具结果：\(result)") }
                try await eventually("答完是 DONE") { rig.lastReply(session) == "DONE" }
            } else {
                #expect(followUps.isEmpty, "拒绝后 Grok 不再请求模型：\(followUps.map(\.results))")
            }
            _ = try await rig.converse("NEXT", in: id)
        }
    }

    @Test(arguments: [Hosting.grok, .dsh])
    func aQuestionIsAnsweredFromCuePadOneByOne(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: .system) { rig in
            rig.model.on("Ask the drink and the size") { request in
                let questions: [[String: any Sendable]] = [
                    ["id": "drink", "question": "Which drink?", "header": "Drink", "multiSelect": false,
                     "options": [["label": "Tea", "description": "hot"], ["label": "Coffee", "description": "strong"]]],
                    ["id": "size", "question": "Which size?", "header": "Size", "multiSelect": false,
                     "options": [["label": "Small", "description": "small cup"], ["label": "Large", "description": "large cup"]]],
                ]
                return request.step == 0 ? .call("ask_user_question", ["questions": questions]) : .say(request.results.last ?? "NO RESULT")
            }
            let id = try await rig.open()
            try await rig.bridge.send(SessionMessage(text: "Ask the drink and the size"), to: id)

            try await eventually("问第一问") { rig.bridge.session(id: id)?.question?.text.contains("Which drink?") == true }
            let drink = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(drink.kind == .known(.select) && drink.options == ["Tea", "Coffee"] && drink.allowsOther && drink.text.contains("Coffee："), "\(drink)")
            await #expect(throws: BridgeError.rejected("bad_answer")) { try await rig.bridge.answer(.option("Milk"), to: try #require(drink.promptID), in: id) }
            try await rig.bridge.answer(.option("Coffee"), to: try #require(drink.promptID), in: id)

            let size = try #require(rig.bridge.session(id: id)?.question)
            #expect(size.text.contains("Which size?") && size.options == ["Small", "Large"] && size.allowsOther && size.promptID != drink.promptID, "\(size)")
            try await rig.bridge.answer(.text("Medium"), to: try #require(size.promptID), in: id)

            let session = try #require(rig.bridge.session(id: id))
            try await eventually("这一轮做完，答案回到回答里") {
                rig.bridge.session(id: id)?.state == .settled && rig.lastReply(session).map { $0.contains("Coffee") && $0.contains("Medium") } == true
            }
            #expect(rig.bridge.session(id: id)?.question == nil)
        }
    }
}
#endif
