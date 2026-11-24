#if os(macOS)
import CueAgent
import CueBridge
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    @Test func 自己醒来出错后隔一会儿重试() async throws {
        let rig = try await Rig(failingOnce: ["醒来：刚启用"], prepare: Rig.handOverWork)
        try await rig.message(.cue, containing: "我看了一眼", skippingBackoff: true)
        #expect(rig.model.errors == 1)
        try await rig.settleTask(titled: "修好登录页 先出一次错")
        try await rig.message(.cue, containing: "登录页那边歇下了", skippingBackoff: true)
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().allSatisfy { !$0.text.contains("bad things happened") })
        await rig.stop()
    }

    @Test func 自己醒来重试也出错才告诉你_这次停下留给你() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 先出两次错")
        try await rig.message(.cue, containing: "bad things happened", skippingBackoff: true)
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().filter { $0.text.contains("bad things happened") }.count == 1)
        try await eventually("Cue 没处理成的停下留给你") { try await rig.store.sessionsAwaitingReply().count == 1 }
        await rig.stop()
    }

    @Test func 自己醒来做完_告诉你结果() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 请收一下")
        let report = try await rig.message(.cue, containing: "做完了")
        #expect(report.text.contains("- 登录测试全过"))
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("结果已告诉用户") }
        #expect(try await rig.store.card(try #require(report.taskID))?.status == .done)
        await rig.stop()
    }

    @Test func 你点完成整件任务_Cue不醒() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        let task = try #require(try await rig.store.cueBoard().tasks.first?.task)
        try await Workspace(services: rig.services).complete(task.id)
        #expect(try await rig.store.card(task.id)?.status == .done)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let keeper = try #require(rig.services.cue.keeper)
        let hello = try #require(keeper.snapshot.rounds.last { $0.wake == .message })
        #expect(hello.sent.joined().contains("变化（上次醒来之后）：无"), "\(hello.sent)")
        #expect(!keeper.snapshot.rounds.contains { $0.sent.joined().contains("[完成]") })
        await rig.stop()
    }
}
#endif