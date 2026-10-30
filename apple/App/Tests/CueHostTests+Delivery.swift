#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    /// Cue 对开着的会话说话，过了说话工具等结果的时限（`CueTiming.sayWait`）Mac 才回报没送达（会话已关闭）：工具如实说还没送达（没有同步，还没发出）；
    /// 失败一到就叫醒 Cue，信封里是"[发送失败] 任务 · 原因"；会话页那句话的气泡写着同一个原因。
    /// 会话开在另一台 Mac 上：说话请求由那台执行，本机的执行器不碰它；时限过后由替身当那台 Mac 写回失败。
    @Test func 说话过了时限才没送达_Cue马上醒来看到原因() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        try await PiStateRecorder(store: rig.store, hostID: "mac-b").update(sessionID: "remote-1", state: .settled, title: "修好登录页")
        try await rig.say("请对登录页说继续")
        try await eventually("这一轮做完") {
            try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("还没送达")
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

    /// 说话工具在等结果的时限内拿到没送到、当场报给 Cue（标成出错、带原因），这一轮好好做完：Cue 已经知道了，这次失败不再进变化。
    @Test func 工具当场报了没送到_这一轮做完后不再报第二遍() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-3")
        try await PiStateRecorder(store: rig.store, hostID: "mac-b").update(sessionID: "remote-3", state: .settled, title: "修好登录页")
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

    /// Cue 说话的工具还在等结果时这一轮断了（大脑被杀；重启、更新、崩溃都是这样）：工具的回应没交到 Cue 手上，
    /// 随后的失败哪怕落在等结果的时限内，也写进下一轮的变化，Cue 醒来看到 [发送失败]。
    @Test func 说话工具等结果时断了_随后的失败下一轮看到() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 半路断开", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-2")
        try await PiStateRecorder(store: rig.store, hostID: "mac-b")
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

    /// Cue 对已结束的本机会话说话，唤醒时它没及时起来（暂时性错误）：执行器隔一会儿重试一次就送到了。
    /// 说话工具等到结果、说已送达（结果由 App 进程写下，`cuepad mcp` 进程订阅库的变化看得到），会话页的气泡是已送达，Cue 收不到失败。
    @Test func 唤醒没及时起来_重试一次送到_Cue不收到失败() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.upsertPiSession(
            IndexedSession(id: "local-1", path: "/sessions/--demo--/local-1.jsonl", cwd: rig.folder.path, title: "修好登录页", lastActivityAt: .now),
            host: TestApp.hostID)
        try await rig.store.linkCard(task.id, toSession: "local-1")
        rig.app.host.resumeFailures = [AgentRuntimeError.launchTimedOut(.pi)]
        try await rig.say("请对登录页说继续")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("已送达") }
        #expect(rig.app.host.calls.count == 2)  // 第一次没起来，重试那次起来了
        let sent = try #require(try await rig.store.deliveryRequests(toSession: "local-1").last)
        #expect(Said.request(sent).trip(at: .always(at: .now)) == .delivered)
        #expect(try await rig.store.cueChanges(after: CueMarks(0)).due.allSatisfy { $0.kind != .undelivered && $0.kind != .failed })
        await rig.stop()
    }

    /// 会话歇下的事件比它写进库早（这台机器忙、或从另一台 Mac 同步过来）：写进库时 Cue 已经做完了一轮、基线已经越过这个时刻，
    /// Cue 仍然要醒来看到它，不能因为事件时刻早于基线就漏掉。
    @Test func 歇下晚到_事件时刻早于上一轮_Cue仍然醒来() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 晚到", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        let remote = PiStateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        let settledAt = Date.now
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        try await remote.update(sessionID: "remote-1", state: .settled, times: PiTimes(stateSince: settledAt, busySince: nil))
        try await rig.answered("remote-1")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        await rig.stop()
    }

    /// Cue 的请求失败晚到（从执行它的那台 Mac 同步过来时，完成时刻早于这台已经知道的另一次失败）：仍是新变化，Cue 醒来看到它。
    @Test func 请求失败晚到_完成时刻更早_Cue仍然醒来() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("修好登录页 说不出去", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-1")
        let remote = PiStateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-1", state: .thinking, title: "修好登录页", turnStartedAt: .now)
        try await remote.update(sessionID: "remote-1", state: .settled)
        try await rig.answered("remote-1")
        try await rig.message(.cue, containing: "登录页那边歇下了")

        /// 你请 Cue 对会话说一句，这一轮做完后由替身当那台 Mac 按 `clock` 的时刻回报没送达，Cue 醒来看到 `reason`。
        func sayFails(_ reason: String, at clock: Timing) async throws {
            try await rig.say("请对登录页说继续")
            // 说话工具等结果至多 `CueTiming.sayWait`：等它交回"还没送达"再替那台 Mac 回报。只看歇着不够——这一轮刚开始时库里还是歇着，
            // 那时回报，说话工具当场拿到没送到，Cue 不会再被叫醒
            let told = rig.model.answers("还没送达")
            try await eventually("这一轮做完") {
                guard rig.model.answers("还没送达") > told, try await rig.store.cueState()?.state == .known(.settled) else { return false }
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
