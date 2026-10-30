#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad

/// 出了问题 Cue 自己接着干：起不来不停在终态、挂住的一轮被看门狗重起、额度用完换一家 Agent、缓存还热时趁热巡视。
extension CueHostTests {
    /// 大脑没了又起不来（这台 Mac 上找不到 Pi）：快的几次重试用完，告诉你一次起不来，此刻是出错；之后隔一阵自己再试，
    /// Pi 回来了就起好；之后第一轮好好做完（答你的话）才说一句又能干活了。
    @Test func 起不来后隔一阵自己再试_起好了说又能干活了() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.milliseconds(500)] })
        let first = try #require(rig.brainPIDs.first)
        rig.launches.set(open: false)
        let before = rig.launches.attempts
        kill(first, SIGKILL)
        try await rig.message(.cue, containing: "我起不来了")
        try await eventually("此刻是出错") { try await rig.store.cueState()?.state == .known(.error) }
        try await eventually("转慢的之后还在试") { rig.launches.attempts >= before + 6 }
        try await eventually("健康是等着重起") { rig.health?.phase == .restarting && rig.health?.nextRetry != nil }
        rig.launches.set(open: true)
        try await eventually("自己起好了") { rig.health?.phase == .running }
        #expect(try await rig.count("又能干活了") == 0)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        try await rig.message(.cue, containing: "又能干活了")
        #expect(try await rig.count("我起不来了") == 1)
        #expect(try await rig.count("又能干活了") == 1)
        try await eventually("健康是值班中") { rig.health?.phase == .running }
        await rig.stop()
    }

    /// 起不来、下一次自己再试还要很久：你发一条消息就马上再试，起好了答你。
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

    /// 一轮里模型一直不回、大脑也没有任何动静：看门狗到点停掉它、重起一个，你的话重新交给新的大脑答。
    @Test func 一轮挂住没动静_看门狗重起_你的话重新交出() async throws {
        let rig = try await Rig(timing: { $0.silence = .seconds(2) })
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("请求挂在模型那里") { rig.model.hanging }
        try await rig.message(.cue, containing: "收到：请慢慢想")
        #expect(!rig.brainPIDs.contains(first))
        await rig.stop()
    }

    /// 你的一轮碰上额度用完，这台 Mac 上还能用 Claude Code：设置换过去（模型清空、fast 关），只说一句从哪换到哪，不再报那个错；
    /// 你的话退回，交给新的大脑答。健康里记着这次换大脑。
    @Test func 额度用完_换到另一家Agent_只说一次() async throws {
        let rig = try await Rig()
        try await rig.store.recordMacAgents(
            host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: []), MacAgent(kind: .claudeCode, model: nil, models: [])])
        try await rig.say("请用到额度用完")
        try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        let profile = try #require(try await rig.store.cueProfile())
        #expect(profile.runtime == .known(.claudeCode) && profile.model == nil && !profile.fast)
        try await eventually("健康里记着换大脑") { rig.health?.failover?.from == .pi && rig.health?.failover?.to == .claudeCode }
        // 替身的 Claude Code 在这台 Mac 上起不来：快的重试用完说起不来，你的话还等着新的大脑
        try await rig.message(.cue, containing: "我起不来了")
        #expect(try await rig.count("接着干") == 1)
        #expect(try await rig.count("这一轮出错了") == 0)
        #expect(try await rig.store.cueMessages().first { $0.text == "请用到额度用完" }?.deliveredAt == nil)
        await rig.stop()
    }

    /// Cue 的工具服务没了（进程退出）：这一轮里工具报错照常做完，做完换个班次（新的大脑带着新的工具服务），之后工具照常能用。
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

    /// 额度用完、这台 Mac 上没有别的 Agent 可换：那个错只说一次，你的这一轮按慢速周期一直重来（信封带上那个错），额度回来了就接着做完。
    @Test func 额度用完又没得换_慢速周期重来直到做完() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.milliseconds(500)] })
        rig.model.blockQuota(times: 3)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "接着做上一轮没做完的")
        #expect(rig.model.errors == 3)
        #expect(try await rig.count("达到用量限制") == 1)
        await rig.stop()
    }

    @Test func 定时额度失败等待重试时_新会话变化不丢掉定时() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let remote = PiStateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-retry", state: .thinking, title: "旁边的工作", turnStartedAt: .now)
        rig.model.blockQuota(times: 1)
        let reminder = try await rig.store.noteCueLine("核对发布结果", source: .you, remindAt: .now)
        try await rig.message(.cue, containing: "达到用量限制")
        try await eventually("一次性定时已触发，正在等慢速重试") {
            guard let keeper = rig.services.cue.keeper else { return false }
            return keeper.setback?.retryAt != nil && keeper.turn == nil
        }
        #expect(try await rig.store.cueLine(reminder.line.id)?.deletedAt != nil)
        try await remote.update(sessionID: "remote-retry", state: .settled)
        try await rig.answered("remote-retry")
        let done = try await rig.message(.cue, containing: "定时到点：#\(reminder.index) 核对发布结果")
        #expect(done.text.contains("一次"))
        let keeper = try #require(rig.services.cue.keeper)
        try await eventually("承接原定时的一轮完成") {
            keeper.rounds.contains { round in
                guard case .schedule(let fires) = round.wake else { return false }
                return fires.contains { $0.line == reminder.line.id } && round.finishedAt != nil && round.failure == nil
            }
        }
        await rig.stop()
    }

    @Test func 持续重试期间新定时不先消费_两项失败都能恢复() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3)] })
        rig.model.blockQuota(times: 1)
        let first = try await rig.store.noteCueLine("核对发布结果 A", source: .you, remindAt: .now)
        let keeper = try #require(rig.services.cue.keeper)
        func waiting(_ id: UUID) -> Bool {
            guard keeper.turn == nil, let held = keeper.setback, held.persistent,
                  case .schedule(let fires) = held.wake else { return false }
            return fires.contains { $0.line == id }
        }
        try await eventually("A 失败后等待重试") { waiting(first.line.id) }
        let second = try await rig.store.noteCueLine("核对发布结果 B", source: .you, remindAt: .now)
        rig.model.blockQuota(times: 1, containing: "醒来：定时到点\n- #\(second.index) 核对发布结果 B")
        // B 已到期，留出对账时间；A 的慢速重试还没到点。
        try await Task.sleep(for: .seconds(1))
        #expect(try await rig.store.cueLine(second.line.id)?.deletedAt == nil)
        #expect(try await rig.store.dueCueSchedules(at: .now).contains { $0.id == second.line.id })
        try await rig.message(.cue, containing: "定时到点：#\(first.index) 核对发布结果 A")
        try await eventually("B 随后失败，也等着持续重试") { waiting(second.line.id) }
        try await rig.message(.cue, containing: "定时到点：#\(second.index) 核对发布结果 B")
        try await eventually("两个定时各自完成") {
            [first.line.id, second.line.id].allSatisfy { id in
                keeper.rounds.contains { round in
                    guard case .schedule(let fires) = round.wake else { return false }
                    return fires.contains { $0.line == id } && round.finishedAt != nil && round.failure == nil
                }
            }
        }
        #expect(rig.model.errors == 2)
        await rig.stop()
    }

    /// 你说完话之后不久（缓存还热）没再说话：Cue 趁热巡视一次，不等冷巡视的空闲时长；这段空闲里只热巡视这一次。
    @Test func 缓存还热时趁热巡视一次() async throws {
        let rig = try await Rig(
            cacheLifetime: .seconds(30), timing: { ($0.warmPatrolAfter, $0.cacheMargin) = (.seconds(2), .seconds(5)) }, prepare: Rig.handOverWork)
        try await rig.message(.cue, containing: "我看了一眼")
        try await rig.say("你好")
        let said = try await rig.message(.cue, containing: "收到：你好")
        let patrol = try await rig.message(.cue, containing: "巡视了一圈")
        let lastYou = try #require(try await rig.store.cueLastYou()?.said)
        #expect(patrol.createdAt.timeIntervalSince(lastYou) >= 2)
        #expect(patrol.createdAt < said.createdAt + 25)
        try await Task.sleep(for: .seconds(4))  // 再过一个热巡视的时长：同一段空闲不再巡视
        #expect(try await rig.count("巡视了一圈") == 1)
        await rig.stop()
    }
}
#endif
