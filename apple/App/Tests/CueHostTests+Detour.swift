#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    /// 重置时刻正赶在 Cue 对账途中（它又试了一次 Claude Code）走过：不能因为排定时器时已过就漏掉，等到下一次重起（一小时后）才换回。
    @Test func 额度用完换到另一家_重置时刻一到换回你选的模型与强度() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let resets = try await stuckPi(rig, resetsIn: 60, alongside: [.claudeCode])
        try await rig.chose(model: "fake/fake-model-2", effort: .high)
        rig.model.blockQuota(times: 1)
        try await rig.say("你好")
        let switched = try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        #expect(switched.text.contains("重置"))
        let away = try #require(try await rig.store.cueProfile())
        #expect(away.runtime == .known(.pi) && away.model == "fake/fake-model-2" && away.effort == .known(.high), "绕行不改你设定的那家")
        try await eventually("健康里记着换大脑") { rig.health?.failover?.from == .pi && rig.health?.failover?.to == .claudeCode }
        try await rig.message(.cue, containing: "我起不来了")
        #expect(try await rig.store.cueMessages().first { $0.text == "你好" }?.deliveredAt == nil)
        try await untilReset(rig, resets)
        #expect(rig.health?.runtime == .claudeCode)

        rig.launches.whenTryingElsewhere { [clocks = rig.clocks] in clocks.jump(to: resets) }
        try #require(rig.services.cue.keeper).input.yield(.kick)  // 你的话等着交：对账时再试一次 Claude Code
        try await rig.message(.cue, containing: "收到：你好")
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

    @Test func 换到的那家也起不来_慢速周期轮回Pi_好了就留下() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(60)] })
        try await rig.store.recordMacAgents(
            host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: []), MacAgent(kind: .claudeCode, model: nil, models: [])])
        try await rig.chose(model: "fake/fake-model-2", effort: .high)
        rig.model.blockQuota(times: 1)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        try await rig.message(.cue, containing: "我起不来了")
        try await rig.message(.cue, containing: "收到：你好", skippingBackoff: true)
        let profile = try #require(try await rig.store.cueProfile())
        #expect(profile.runtime == .known(.pi) && profile.model == "fake/fake-model-2" && profile.effort == .known(.high))
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        // 远处排一个定时：好了之后手上没有排着的时刻，对账后不睡下就等不到
        _ = try await rig.store.noteCueLine("下周的事", source: .you, remindAt: rig.clock.now.addingTimeInterval(7 * 86_400))
        rig.jump(by: .seconds(120))  // 再过两个慢速周期：好了就留下，不再换
        try await rig.reconciled()
        #expect(rig.health?.runtime == .pi)
        #expect(try await rig.count("收到：你好") == 1)
        #expect(try await rig.count("又能干活了") == 1)
        #expect(try await rig.count("我起不来了") == 1)
        #expect(try await rig.count("接着干") == 1)
        await rig.stop()
    }

    @Test func 定时卡住换家又起不来_重置时刻一到换回Pi做完定时() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let resets = try await stuckPi(rig, resetsIn: 60, alongside: [.claudeCode])
        rig.model.blockQuota(times: 1)
        let reminder = try await rig.store.noteCueLine("核对发布结果", source: .you, remindAt: .now)
        try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        try await rig.message(.cue, containing: "我起不来了")
        try await untilReset(rig, resets)
        #expect(try await rig.count("定时到点") == 0)
        rig.jump(to: resets)
        try await rig.message(.cue, containing: "定时到点：\(reminder.id.uuidString.lowercased()) 核对发布结果")
        #expect(rig.health?.runtime == .pi)
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        #expect(rig.model.errors == 1)
        #expect(try await rig.count("又能干活了") == 1)
        await rig.stop()
    }

    @Test func 额度用完没得换_重置时刻一到就重来() async throws {
        let rig = try await Rig(timing: { $0.slowRestarts = [.seconds(3600)] })
        let resets = try await stuckPi(rig, resetsIn: 60, alongside: [])
        rig.model.blockQuota(times: 1)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "达到用量限制")
        try await untilReset(rig, resets)
        #expect(try await rig.count("收到：你好") == 0)
        rig.jump(to: resets)
        try await rig.message(.cue, containing: "收到：你好")
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        #expect(try await rig.count("达到用量限制") == 1)
        #expect(rig.model.errors == 1)
        await rig.stop()
    }

    enum Stuck: Sendable { case message, schedule }

    /// 它起不来、快的重试还没用完（你的话等着交时每次对账都马上再试一次，快的那几次留得够多），Pi 就到了重置时刻，换回 Pi 做完卡着的那件。
    @Test(arguments: [Stuck.message, .schedule])
    func 换家后做完卡着的那件_说一句恢复了_不说起不来(_ stuck: Stuck) async throws {
        let rig = try await Rig(timing: { ($0.restarts, $0.slowRestarts) = (Array(repeating: .seconds(3600), count: 8), [.seconds(3600)]) })
        let resets = try await stuckPi(rig, resetsIn: 60, alongside: [.claudeCode])
        rig.model.blockQuota(times: 1)
        let done: String
        switch stuck {
        case .message:
            try await rig.say("你好")
            done = "收到：你好"
        case .schedule:
            let reminder = try await rig.store.noteCueLine("核对发布结果", source: .you, remindAt: .now)
            done = "定时到点：\(reminder.id.uuidString.lowercased()) 核对发布结果"
        }
        try await rig.message(.cue, containing: "我换到 Claude Code 接着干")
        try await eventually("Claude Code 起不来，等着重起") { rig.health?.runtime == .claudeCode && rig.health?.phase == .restarting }
        rig.jump(to: resets)
        try await rig.message(.cue, containing: done)
        try await rig.message(.cue, containing: "又能干活了，用的是 Pi")
        #expect(try await rig.count("接着干") == 1)
        #expect(try await rig.count("又能干活了") == 1)
        #expect(try await rig.count("我起不来了") == 0)
        await rig.stop()
    }

    private func untilReset(_ rig: Rig, _ resets: Date) async throws {
        rig.jump(to: resets - 1)
        try await rig.reconciled()
    }

    private func stuckPi(_ rig: Rig, resetsIn seconds: TimeInterval, alongside others: [AgentKind]) async throws -> Date {
        let account = PiAccount(kind: .oauth, scope: "fake-plan", name: "fake")
        let model = ModelOption(key: ModelKey(provider: "fake", id: "fake-model-2"), name: "Fake Model 2", thinkingLevels: [.high], account: account)
        try await rig.store.recordMacAgents(
            host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: model.key, models: [model])] + others.map { MacAgent(kind: $0, model: nil, models: []) })
        let resets = rig.clock.now.addingTimeInterval(seconds)
        let window = QuotaWindow(seconds: 18_000, used: 1, resetsAt: resets, isBinding: true)
        try await rig.store.recordQuota(QuotaReport(provider: "fake", windows: [window], complete: true, account: account), host: TestApp.hostID)
        return resets
    }
}
#endif
