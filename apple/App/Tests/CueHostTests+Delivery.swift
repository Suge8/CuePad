#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    /// 会话开在另一台 Mac 上：说话请求由那台执行，本机的执行器不碰它；时限过后由替身当那台 Mac 写回失败。
    /// 要的是等过时限，与时长无关：时限缩短（等结果在 `cuepad mcp` 子进程里，只能真等）。
    @Test func 说话过了时限才没送达_Cue马上醒来看到原因() async throws {
        let rig = try await Rig(timing: { $0.sayWait = 0.5 })
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        try await rig.remoteMac().update(sessionID: "remote-1", state: .settled, title: "修好登录页")
        try await rig.say("请对登录页说继续")
        try await eventually("这一轮做完") {
            try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("送达尚未确认")
        }
        let sent = try #require(try await rig.store.deliveryRequests(toSession: "remote-1").last)
        #expect(sent.hostID == "mac-b" && sent.isOpen && sent.isFromCue)

        let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", onIssue: { Issue.record("\($0)") }) { _, _ in .failed(.verbatim("会话已关闭")) }
        try await macB.start()
        let seen = try await rig.message(.cue, containing: "看到了")
        #expect(seen.text.contains("[发送失败] 修好登录页 说不出去") && seen.text.contains("会话已关闭"), "\(seen.text)")
        let failed = try #require(try await rig.store.deliveryRequest(sent.id))
        #expect(Said.request(failed).trip(at: .always(at: .now)) == .failed(.reported("会话已关闭")))
        await macB.stop()
        await rig.stop()
    }

    @Test func 工具当场报了没送到_这一轮做完后不再报第二遍() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-3")
        try await rig.remoteMac().update(sessionID: "remote-3", state: .settled, title: "修好登录页")
        let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", onIssue: { Issue.record("\($0)") }) { _, _ in .failed(.verbatim("会话已关闭")) }
        try await macB.start()
        try await rig.say("请对登录页说继续")
        try await eventually("工具当场报了没送到") { rig.model.answered("没送到——会话已关闭") }
        try await eventually("这一轮做完、记下 Cue 已知道") {
            let failed = try await rig.store.deliveryRequests(toSession: "remote-3").contains { $0.failure != nil }
            let reported = try await rig.store.cueChanges(after: CueMarks(0)).due.contains { $0.kind == .undelivered }
            return failed && !reported
        }
        await macB.stop()
        await rig.stop()
    }

    @Test func 说话工具等结果时断了_随后的失败下一轮看到() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 半路断开", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-2")
        try await rig.remoteMac()
            .update(sessionID: "remote-2", state: .settled, title: "修好登录页", turnStartedAt: .now)
        try await rig.answered("remote-2")
        try await eventually("Cue 说了话、工具在等结果") {
            try await rig.store.deliveryRequests(toSession: "remote-2").contains { $0.isOpen && $0.isFromCue }
        }
        let brain = try #require(rig.brainPIDs.first)
        kill(brain, SIGKILL)

        let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", onIssue: { Issue.record("\($0)") }) { _, _ in .failed(.verbatim("会话已关闭")) }
        try await macB.start()
        let seen = try await rig.message(.cue, containing: "看到了")
        #expect(seen.text.contains("[发送失败] 修好登录页 半路断开") && seen.text.contains("会话已关闭"), "\(seen.text)")
        await macB.stop()
        await rig.stop()
    }

    @Test func 歇下晚到_事件时刻早于上一轮_Cue仍然醒来() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 晚到", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        let remote = StateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        let settledAt = Date.now
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        try await remote.update(sessionID: "remote-1", state: .settled, times: SessionTimes(stateSince: settledAt, busySince: nil))
        try await rig.answered("remote-1")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        await rig.stop()
    }

    /// 每次都等说话工具过了时限才回报：时限缩短，同上一条。
    @Test func 请求失败晚到_完成时刻更早_Cue仍然醒来() async throws {
        let rig = try await Rig(timing: { $0.sayWait = 0.5 })
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await rig.message(.cue, containing: "登录页那边歇下了")

        func sayFails(_ reason: String, at clock: Timing) async throws {
            try await rig.say("请对登录页说继续")
            // 说话工具等结果至多 `CueTiming.sayWait`：等它交回"送达尚未确认"再替那台 Mac 回报。只看歇着不够——这一轮刚开始时库里还是歇着，
            // 那时回报，说话工具当场拿到没送到，Cue 不会再被叫醒
            let told = rig.model.answers("送达尚未确认")
            try await eventually("这一轮做完") {
                guard rig.model.answers("送达尚未确认") > told, try await rig.store.cueState()?.state == .known(.settled) else { return false }
                return try await rig.store.deliveryRequests(toSession: "remote-1").contains { $0.isOpen }
            }
            let macB = DeliveryExecutor(store: rig.store, hostID: "mac-b", timing: clock, onIssue: { Issue.record("\($0)") }) { _, _ in .failed(.verbatim(reason)) }
            try await macB.start()
            try await rig.message(.cue, containing: reason)
            await macB.stop()
        }
        try await sayFails("会话已关闭", at: .system)
        try await sayFails("早一小时就关了", at: ManualTiming(start: .now.addingTimeInterval(-3600)).timing)
        await rig.stop()
    }
}
#endif
