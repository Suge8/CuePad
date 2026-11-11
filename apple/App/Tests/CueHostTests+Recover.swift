#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    @Test func 起不来后隔一阵自己再试_起好了说又能干活了() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(60)] })
        let first = try #require(rig.brainPIDs.first)
        rig.launches.set(open: false)
        let before = rig.launches.attempts
        kill(first, SIGKILL)
        try await rig.message(.cue, containing: "我起不来了", skippingBackoff: true)
        try await eventually("此刻是出错") { try await rig.store.cueState()?.state == .known(.error) }
        try await eventually("转慢的之后还在试") {
            rig.skipBackoff()
            return rig.launches.attempts >= before + 6
        }
        try await eventually("健康是等着重起") { rig.health?.phase == .restarting && rig.health?.nextRetry != nil }
        rig.launches.set(open: true)
        try await eventually("自己起好了") {
            rig.skipBackoff()
            return rig.health?.phase == .running
        }
        #expect(try await rig.count("又能干活了") == 0)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        try await rig.message(.cue, containing: "又能干活了")
        #expect(try await rig.count("我起不来了") == 1)
        #expect(try await rig.count("又能干活了") == 1)
        try await eventually("健康是值班中") { rig.health?.phase == .running }
        await rig.stop()
    }

    @Test func 起不来时你发消息_马上再试() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let first = try #require(rig.brainPIDs.first)
        rig.launches.set(open: false)
        kill(first, SIGKILL)
        try await rig.message(.cue, containing: "我起不来了")
        rig.launches.set(open: true)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        await rig.stop()
    }

    @Test func 一轮挂住没动静_看门狗重起_你的话重新交出() async throws {
        let rig = try await Rig(timing: { $0.silence = .seconds(60) })
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("请求挂在模型那里") { rig.model.hanging }
        try await stalled(rig, first)
        try await rig.message(.cue, containing: "收到：请慢慢想")
        await rig.stop()
    }

    @Test func Mac睡着时一轮在跑_醒来不当成卡住() async throws {
        let rig = try await Rig(timing: { $0.silence = .seconds(60) })
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("请求挂在模型那里") { rig.model.hanging }
        rig.jump(by: .seconds(120), asleep: true)  // 合盖的这段：墙钟走过两个看门狗的时长
        try await rig.reconciled()
        #expect(rig.brainPIDs == [first])
        #expect(try await rig.count("收到：请慢慢想") == 0)
        try await stalled(rig, first)
        try await rig.message(.cue, containing: "收到：请慢慢想")
        await rig.stop()
    }

    private func stalled(_ rig: Rig, _ brain: pid_t) async throws {
        try await eventually("看门狗停掉挂住的大脑") {
            guard rig.brainPIDs.contains(brain) else { return true }
            rig.skipSilence()
            return false
        }
    }

    @Test func 工具服务没了_这一轮做完换个班次() async throws {
        let rig = try await Rig()
        let brain = try #require(rig.brainPIDs.first), tools = try #require(rig.toolServerPIDs.first)
        kill(tools, SIGKILL)
        try await rig.say("请问我一个问题")
        try await eventually("换了个班次") { rig.brainPIDs.count == 1 && !rig.brainPIDs.contains(brain) }
        try await rig.say("请问我一个问题")
        try await rig.message(.cue, containing: "要推送吗？")
        await rig.stop()
    }

    @Test func 额度用完又没得换_慢速周期重来直到做完() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(60)] })
        rig.model.blockQuota(times: 3)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "接着做上一轮没做完的", skippingBackoff: true)
        #expect(rig.model.errors == 3)
        #expect(try await rig.count("达到用量限制") == 1)
        await rig.stop()
    }

    @Test func 额度卡住时新变化不催重来_你的一轮做完就接着做定时() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let remote = StateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-retry", state: .thinking, title: "旁边的工作", turnStartedAt: .now)
        rig.model.blockQuota(times: 1)
        let reminder = try await rig.store.noteCueLine("核对发布结果", source: .you, remindAt: .now)
        try await rig.message(.cue, containing: "达到用量限制")
        let keeper = try #require(rig.services.cue.keeper)
        try await eventually("一次性定时已触发，正在等慢速重试") { keeper.setback?.retryAt != nil && keeper.turn == nil }
        #expect(try await rig.store.cueLine(reminder.id)?.deletedAt != nil)
        try await remote.update(sessionID: "remote-retry", state: .settled)
        try await rig.answered("remote-retry")
        try await rig.reconciled()  // 新变化对过账：不该叫它重来
        #expect(rig.model.errors == 1 && keeper.turn == nil)
        #expect(try await rig.count("定时到点") == 0)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let done = try await rig.message(.cue, containing: "定时到点：\(reminder.id.uuidString.lowercased()) 核对发布结果")
        #expect(done.text.contains("一次"))
        #expect(rig.model.errors == 1)
        try await eventually("承接原定时的一轮完成") {
            keeper.rounds.contains { round in
                guard case .schedule(let fires) = round.wake else { return false }
                return fires.contains { $0.line == reminder.id } && round.finishedAt != nil && round.failure == nil
            }
        }
        await rig.stop()
    }

    @Test func 持续重试期间新定时不先消费_两项失败都能恢复() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(60)] })
        rig.model.blockQuota(times: 1)
        let first = try await rig.store.noteCueLine("核对发布结果 A", source: .you, remindAt: .now)
        let keeper = try #require(rig.services.cue.keeper)
        func waiting(_ id: UUID) -> Bool {
            guard keeper.turn == nil, let held = keeper.setback, held.persistent,
                  case .schedule(let fires) = held.wake else { return false }
            return fires.contains { $0.line == id }
        }
        try await eventually("A 失败后等待重试") { waiting(first.id) }
        let second = try await rig.store.noteCueLine("核对发布结果 B", source: .you, remindAt: .now)
        rig.model.blockQuota(times: 1, containing: "醒来：定时到点\n- \(second.id.uuidString.lowercased()) 核对发布结果 B")
        try await rig.reconciled()
        #expect(try await rig.store.cueLine(second.id)?.deletedAt == nil)
        #expect(try await rig.store.dueCueSchedules(at: rig.clock.now).contains { $0.id == second.id })
        try await rig.message(.cue, containing: "定时到点：\(first.id.uuidString.lowercased()) 核对发布结果 A", skippingBackoff: true)
        try await eventually("B 随后失败，也等着持续重试") { waiting(second.id) }
        try await rig.message(.cue, containing: "定时到点：\(second.id.uuidString.lowercased()) 核对发布结果 B", skippingBackoff: true)
        try await eventually("两个定时各自完成") {
            [first.id, second.id].allSatisfy { id in
                keeper.rounds.contains { round in
                    guard case .schedule(let fires) = round.wake else { return false }
                    return fires.contains { $0.line == id } && round.finishedAt != nil && round.failure == nil
                }
            }
        }
        #expect(rig.model.errors == 2)
        await rig.stop()
    }

    @Test func 缓存还热时趁热巡视一次() async throws {
        let warm = Duration.seconds(60)
        let rig = try await Rig(
            cacheLifetime: .seconds(600), timing: { ($0.warmPatrolAfter, $0.cacheMargin) = (warm, .seconds(60)) }, prepare: Rig.handOverWork)
        try await rig.message(.cue, containing: "我看了一眼")
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let lastYou = try #require(try await rig.store.cueLastYou()?.said)
        rig.jump(to: lastYou + warm.seconds - 1)
        try await rig.reconciled()
        #expect(try await rig.count("巡视了一圈") == 0)  // 热巡视的时长差一刻还不巡视
        rig.jump(to: lastYou + warm.seconds)  // 离冷巡视（一小时）、缓存过期都还远
        try await rig.message(.cue, containing: "巡视了一圈")
        try await eventually("巡视的这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        rig.jump(by: warm)  // 再过一个热巡视的时长：同一段空闲不再巡视
        try await rig.reconciled()
        #expect(try await rig.count("巡视了一圈") == 1)
        await rig.stop()
    }
}
#endif
