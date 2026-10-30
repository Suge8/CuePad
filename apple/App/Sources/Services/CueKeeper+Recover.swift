#if os(macOS)
import CueAgent
import CuePi
import CueStore
import Foundation

/// 出了问题怎么自己接着干：看门狗、自动换大脑、起不来与恢复时说的话、大脑健康的本机投影（`CueHealth`）。
extension CueKeeper {
    // MARK: 看门狗

    /// 一轮开始（或这一轮里有大脑事件）：截止时刻推到此刻之后 `CueTiming.silence`。看门狗一个就够，睡到截止时刻醒来看一眼：
    /// 这期间有过事件就睡到新的截止时刻，没有就报 `.silent`；一轮做完（不论哪个班次）就退出，下一轮开始再起。
    func heard() {
        heardAt = .now
        guard turn != nil, watchdog == nil else { return }
        let limit = setup.timing.silence.seconds, input = input
        watchdog = Task {
            defer { watchdog = nil }
            while turn != nil, !Task.isCancelled {
                let wait = (heardAt + limit).timeIntervalSinceNow
                guard wait > 0 else {
                    input.yield(.silent)
                    return
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// `.silent` 到了：还是那么久没动静就当大脑挂了（停掉，按 `broke` 重起、交出去的话重新交）。
    func silenced() async {
        guard turn != nil, Date.now >= heardAt + setup.timing.silence.seconds else { return }
        let minutes = Int(setup.timing.silence.seconds / 60)
        await broke(ShownText("这一轮 \(minutes) 分钟没有动静，大脑像是卡住了"))
    }

    /// 工具结果说 Cue 的工具服务（`cuepad mcp`）没了（Pi 的接入 `cue-tools.ts` 报的）：这个班次的工具用不了了，做完这一轮就换。
    static func toolsDown(_ result: String) -> Bool { result.contains(/CuePad 的工具服务.*(退出了|没有回应)/) }

    // MARK: 换大脑

    /// 额度、登录卡住（不重试的错）：这台 Mac 上另有能用、这次故障里还没试过的 Agent，就把设置换过去（模型清空、fast 关），
    /// 返回告诉你的那句（从哪换到哪、为什么、额度读得到就带重置时刻）。换不了为 nil：照常报错，起不来的按慢速重试。
    /// 换回原来那家由 Cue 自己定（记忆、定时与 `setup set`），这里不自动换回；`tried` 在一轮好好做完时清空。
    func failOver(_ failure: String) async -> ShownText? {
        let summary = PiErrorSummary(failure)
        guard !summary.failure.retries, let from = brainSettings?.runtime.known else { return nil }
        tried.insert(from)
        do {
            let agents = try await store.macAgents(on: setup.recorder.hostID)
            let kinds = agents.kinds
            // 下一家：按 `AgentKind` 的顺序排在它后面的先，再绕回前面
            guard let to = (Array(kinds.drop { $0 != from }.dropFirst()) + kinds).first(where: { !tried.contains($0) }) else { return nil }
            let resets = await resetsAt(agents.agent(from), kind: from, model: brainSettings?.model)
            _ = try await store.updateCueProfile { profile in
                profile.runtime = .known(to)
                profile.model = nil
                profile.fast = false
            }
            await setup.upload([CueProfile.recordID])
            failover = CueHealth.Failover(from: from, to: to, reason: summary.title, at: .now)
            Self.log.notice("Cue 换大脑：\(from.rawValue, privacy: .public) → \(to.rawValue, privacy: .public)（\(summary.title, privacy: .public)）")
            let why = summary.shownTitle.embedded
            guard let resets else { return ShownText("\(from.name) \(why)，我换到 \(to.name) 接着干。") }
            let at = resets.formatted(Calendar.current.isDateInToday(resets) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute())
            return ShownText("\(from.name) \(why)（\(at) 重置），我换到 \(to.name) 接着干。")
        } catch {
            Self.log.error("Cue 没能换大脑：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 那家在用的模型（没指定是它的默认）关联的额度此刻卡着的窗口何时重置；读不到为 nil。
    private func resetsAt(_ agent: MacAgent?, kind: AgentKind, model: String?) async -> Date? {
        guard let agent,
              let option = model.flatMap(kind.modelKey).flatMap({ key in agent.models.first { $0.key == key } }) ?? agent.defaultModel,
              let quotas = try? await store.accountQuotas(),
              let quota = PiModelLabel.quota(option, quotas: quotas)
        else { return nil }
        return quota.binding(at: .now, model: option.key.id)?.resetsAt
    }

    // MARK: 起不来与恢复

    /// 快的重试用完、要转慢的了：这次故障里说一次起不来（提示你），之后不再说，恢复时说一句（`recovered`）。
    func tellDown(_ reason: ShownText) async {
        guard !outageTold else { return }
        outageTold = true
        await say(.cue, ShownText("我起不来了：\(reason.embedded)\n我隔一阵会自己再试；你发条消息，我马上再试。"), urgent: true)
    }

    /// 说过起不来之后大脑又起好了。
    func recovered() async {
        guard outageTold else { return }
        outageTold = false
        await say(.cue, ShownText("又能干活了。"))
    }

    // MARK: 健康

    /// 此刻的健康（`CueHealth`）：由 `phase` 与最近的出错、换大脑直接得出。
    var health: CueHealth {
        var health = CueHealth(phase: .starting, runtime: brainSettings?.runtime.known, model: brainSettings?.model, lastFailure: trouble, failover: failover)
        switch phase {
        case .starting(let failures): health.failures = failures
        case .running(let shift):
            (health.phase, health.shiftStartedAt, health.failures) = (.running, shift.startedAt, shift.failures)
        case .restarting(let failures, _, let at):
            (health.phase, health.failures, health.nextRetry) = (.restarting, failures, at)
        }
        return health
    }

    /// 健康和上次写的不一样才写（每次对完账都来）。
    func writeHealth() {
        let health = health
        guard health != writtenHealth else { return }
        do {
            try health.write(library: setup.library)
            writtenHealth = health
        } catch {
            Self.log.error("Cue 的健康没能写下：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 不再值班：健康文件删掉（读的那边是"不在这台值班"）。
    func clearHealth() {
        guard writtenHealth != nil else { return }
        do {
            try FileManager.default.removeItem(at: CueHealth.file(in: setup.library))
        } catch {
            Self.log.error("Cue 的健康文件没能删掉：\(error.localizedDescription, privacy: .public)")
        }
        writtenHealth = nil
    }
}
#endif
