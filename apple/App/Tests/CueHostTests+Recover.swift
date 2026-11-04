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

    /// Mac 睡着正赶上一轮在跑：睡着的那段不算没动静，醒来不把大脑当成卡住、不重起；醒着又那么久没动静，看门狗才重起、你的话重新交。
    @Test func Mac睡着时一轮在跑_醒来不当成卡住() async throws {
        let clock = AwakeClock()
        let rig = try await Rig(timing: {
            $0.silence = .seconds(2)
            $0.awake = { clock.now() }
        })
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("请求挂在模型那里") { rig.model.hanging }
        clock.sleep()
        try await Task.sleep(for: .seconds(4))  // 合盖的这段：墙钟走过两个看门狗的时长
        #expect(rig.brainPIDs == [first])
        #expect(try await rig.count("收到：请慢慢想") == 0)
        clock.wake()
        try await rig.message(.cue, containing: "收到：请慢慢想")
        #expect(!rig.brainPIDs.contains(first))
        await rig.stop()
    }

    /// 你在 Cue 页选了 Pi 的 Fake Model 2、强度高，你的一轮碰上 Pi 额度用完（读得到几点重置），这台 Mac 上还能用 Claude Code：
    /// 设置换过去（模型清空、fast 关），只说一句从哪换到哪、几点重置，不再报那个错；健康里记着这次换大脑。替身的 Claude Code 在这台 Mac 上起不来：
    /// 说一次起不来，你的话还等着。到了 Pi 的重置时刻（慢速重试还远）换回 Pi，连同你选的模型与强度，你的话交给它答一次，说一句恢复了。
    @Test func 额度用完换到另一家_重置时刻一到换回你选的模型与强度() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let account = PiAccount(kind: .oauth, scope: "fake-plan", name: "fake")
        let model = PiModelOption(key: PiModelKey(provider: "fake", id: "fake-model-2"), name: "Fake Model 2", thinkingLevels: [.high], account: account)
        try await rig.store.recordMacAgents(
            host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: model.key, models: [model]), MacAgent(kind: .claudeCode, model: nil, models: [])])
        let resets = Date.now.addingTimeInterval(5)
        let window = QuotaWindow(seconds: 18_000, used: 1, resetsAt: resets, isBinding: true)
        try await rig.store.recordQuota(QuotaReport(provider: "fake", windows: [window], complete: true, account: account), host: TestApp.hostID)
        try await rig.chose(model: "fake/fake-model-2", effort: .high)
        rig.model.blockQuota(times: 1)
        try await rig.say("你好")
        let switched = try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        #expect(switched.text.contains("重置"))
        let away = try #require(try await rig.store.cueProfile())
        #expect(away.runtime == .known(.claudeCode) && away.model == nil && !away.fast)
        try await eventually("健康里记着换大脑") { rig.health?.failover?.from == .pi && rig.health?.failover?.to == .claudeCode }
        try await rig.message(.cue, containing: "我起不来了")
        #expect(try await rig.store.cueMessages().first { $0.text == "你好" }?.deliveredAt == nil)

        try await rig.message(.cue, containing: "收到：你好")
        #expect(Date.now >= resets)
        let home = try #require(try await rig.store.cueProfile())
        #expect(home.runtime == .known(.pi) && home.model == "fake/fake-model-2" && home.effort == .known(.high))
        let used = try #require(rig.model.requests.last)
        #expect(used.model == "fake-model-2" && used.effort == "high", "\(rig.model.requests)")
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        #expect(try await rig.count("收到：你好") == 1)
        #expect(try await rig.count("又能干活了") == 1)
        #expect(try await rig.count("接着干") == 1)
        #expect(try await rig.count("这一轮出错了") == 0)
        await rig.stop()
    }

    /// 额度用完（读不到几点重置）换到 Claude Code，那家也起不来：不一直守着它重试，慢速周期到点轮到 Pi 再试（每个周期只试一家），
    /// Pi 好了就留在 Pi、你选的模型与强度照旧，你的话答上一次，只在答上的那一轮说一句恢复了。
    @Test func 换到的那家也起不来_慢速周期轮回Pi_好了就留下() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(1)] })
        try await rig.store.recordMacAgents(
            host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: []), MacAgent(kind: .claudeCode, model: nil, models: [])])
        try await rig.chose(model: "fake/fake-model-2", effort: .high)
        rig.model.blockQuota(times: 1)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        try await rig.message(.cue, containing: "我起不来了")
        try await rig.message(.cue, containing: "收到：你好")
        let profile = try #require(try await rig.store.cueProfile())
        #expect(profile.runtime == .known(.pi) && profile.model == "fake/fake-model-2" && profile.effort == .known(.high))
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        try await Task.sleep(for: .seconds(2))  // 再过两个慢速周期：好了就留下，不再换
        #expect(try await rig.store.cueProfile()?.runtime == .known(.pi))
        #expect(try await rig.count("收到：你好") == 1)
        #expect(try await rig.count("又能干活了") == 1)
        #expect(try await rig.count("我起不来了") == 1)
        #expect(try await rig.count("接着干") == 1)
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

    /// 定时那一轮额度用完、又没得换：卡着时新来的会话变化不催它重来（重来只会再失败），定时也不丢；
    /// 你的话照常答，答好了说明额度回来了，卡着的定时马上接着做完，不等慢速周期。
    @Test func 额度卡住时新变化不催重来_你的一轮做完就接着做定时() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let remote = PiStateRecorder(store: rig.store, hostID: "mac-b")
        try await remote.update(sessionID: "remote-retry", state: .thinking, title: "旁边的工作", turnStartedAt: .now)
        rig.model.blockQuota(times: 1)
        let reminder = try await rig.store.noteCueLine("核对发布结果", source: .you, remindAt: .now)
        try await rig.message(.cue, containing: "达到用量限制")
        let keeper = try #require(rig.services.cue.keeper)
        try await eventually("一次性定时已触发，正在等慢速重试") { keeper.setback?.retryAt != nil && keeper.turn == nil }
        #expect(try await rig.store.cueLine(reminder.line.id)?.deletedAt != nil)
        try await remote.update(sessionID: "remote-retry", state: .settled)
        try await rig.answered("remote-retry")
        try await Task.sleep(for: .seconds(1))  // 留出对账的时间：新变化不该叫它重来
        #expect(rig.model.errors == 1 && keeper.turn == nil)
        #expect(try await rig.count("定时到点") == 0)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let done = try await rig.message(.cue, containing: "定时到点：#\(reminder.index) 核对发布结果")
        #expect(done.text.contains("一次"))
        #expect(rig.model.errors == 1)
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
