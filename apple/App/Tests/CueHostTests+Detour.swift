#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 额度、登录卡住时换家（绕行）：换到能用的那家、你设定的那家重置一到就回去、都卡着时每个慢速周期换一家试，好了就留下。
extension CueHostTests {
    /// 你在 Cue 页选了 Pi 的 Fake Model 2、强度高，你的一轮碰上 Pi 额度用完（读得到几点重置），这台 Mac 上还能用 Claude Code：
    /// 设置换过去（模型清空、fast 关），只说一句从哪换到哪、几点重置，不再报那个错；健康里记着这次换大脑。替身的 Claude Code 在这台 Mac 上起不来：
    /// 说一次起不来，你的话还等着。到了 Pi 的重置时刻（慢速重试还远）换回 Pi，连同你选的模型与强度，你的话交给它答一次，说一句恢复了。
    @Test func 额度用完换到另一家_重置时刻一到换回你选的模型与强度() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let resets = try await stuckPi(rig, resetsIn: 5, alongside: [.claudeCode])
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

    /// 定时那一轮碰上 Pi 额度用完（读得到几点重置），换到 Claude Code 又起不来，手上没有要交给它的话：到了 Pi 的重置时刻（慢速重试还远）
    /// 换回 Pi、起好，卡着的定时接着做完，说一句恢复了。
    @Test func 定时卡住换家又起不来_重置时刻一到换回Pi做完定时() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let resets = try await stuckPi(rig, resetsIn: 5, alongside: [.claudeCode])
        rig.model.blockQuota(times: 1)
        let reminder = try await rig.store.noteCueLine("核对发布结果", source: .you, remindAt: .now)
        try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        try await rig.message(.cue, containing: "我起不来了")
        try await rig.message(.cue, containing: "定时到点：#\(reminder.index) 核对发布结果")
        #expect(Date.now >= resets)
        #expect(try await rig.store.cueProfile()?.runtime == .known(.pi))
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        #expect(rig.model.errors == 1)
        #expect(try await rig.count("又能干活了") == 1)
        await rig.stop()
    }

    /// 你的一轮碰上额度用完，这台 Mac 上只有 Pi（读得到几点重置）：那个错只说一次；不等慢速重试（还远），到了重置时刻就重来、做完，说一句恢复了。
    @Test func 额度用完没得换_重置时刻一到就重来() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let resets = try await stuckPi(rig, resetsIn: 5, alongside: [])
        rig.model.blockQuota(times: 1)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "达到用量限制")
        try await rig.message(.cue, containing: "接着做上一轮没做完的")
        #expect(Date.now >= resets)
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        #expect(try await rig.count("达到用量限制") == 1)
        #expect(rig.model.errors == 1)
        await rig.stop()
    }

    /// 这台 Mac 上能用 Pi（默认模型 Fake Model 2，额度读得到：此刻用满、`seconds` 秒后重置）与 `others`；返回重置时刻。
    private func stuckPi(_ rig: Rig, resetsIn seconds: TimeInterval, alongside others: [AgentKind]) async throws -> Date {
        let account = PiAccount(kind: .oauth, scope: "fake-plan", name: "fake")
        let model = PiModelOption(key: PiModelKey(provider: "fake", id: "fake-model-2"), name: "Fake Model 2", thinkingLevels: [.high], account: account)
        try await rig.store.recordMacAgents(
            host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: model.key, models: [model])] + others.map { MacAgent(kind: $0, model: nil, models: []) })
        let resets = Date.now.addingTimeInterval(seconds)
        let window = QuotaWindow(seconds: 18_000, used: 1, resetsAt: resets, isBinding: true)
        try await rig.store.recordQuota(QuotaReport(provider: "fake", windows: [window], complete: true, account: account), host: TestApp.hostID)
        return resets
    }
}
#endif
