#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import Foundation

/// 取舍：换回只认读得到的重置时刻，不为探你设定的那家好没好而反复换大脑（每换一次丢一次会话与提示缓存）；读不到的（登录）留在能用的那家，换回由你或 Cue 定。
extension CueKeeper {

    /// 定时器照墙钟睡，睡着的 Mac 醒来时它先到点：看门狗按醒着的时长再算一次（`revive`），没满就按剩下的重排。
    func alarm(at now: Date) -> Date? {
        let brain: Date? = switch phase {
        case .restarting(_, _, let at): at
        case .running(let shift) where shift.turn != nil: now + (setup.timing.silence - quiet).seconds
        case .starting, .running: nil
        }
        let retry = owed.isEmpty && unfired.isEmpty ? nil : now + setup.timing.returnRetry.seconds
        return [brain, retry, detour?.nextReset(after: now)].compactMap(\.self).min()
    }

    /// Mac 睡着的那段不算（`CueTiming.awake`）。
    private var quiet: Duration { setup.timing.awake() - heardAt }

    func revive(at now: Date) async {
        switch phase {
        case .restarting(let failures, _, let at) where at <= now:
            _ = await steer(attempt: true, at: now)
            await startShift(failures: failures)
        case .running(let shift) where shift.turn != nil && quiet >= setup.timing.silence:
            let minutes = Int(setup.timing.silence.seconds / 60)
            await broke(ShownText("这一轮 \(minutes) 分钟没有动静，大脑像是卡住了"))
        case .starting, .running, .restarting: break
        }
    }

    /// 返回告诉你的那句；nil 是没换：照常报错，慢速周期到点再换着试（`steer`）。换了就是改 `detour.to`，下一次对账按它换大脑（`BrainSettings`）。
    func failOver(_ failure: String) async -> ShownText? {
        let summary = ErrorSummary(failure)
        guard !summary.failure.retries, let settings = brainSettings, let from = settings.runtime.known else { return nil }
        let now = self.now
        do {
            let agents = try await store.macAgents(on: setup.recorder.hostID)
            let resets = await resetsAt(agents.agent(from), kind: from, model: settings.model)
            var detour = self.detour ?? Detour(to: from)
            detour.stuck[from] = Detour.Stuck(at: now, resets: resets)
            self.detour = detour
            let home = try await store.cueProfile()?.runtime.known
            guard let (to, open) = detour.next(from: from, home: home, among: agents.kinds, at: now), open, to != from else { return nil }
            use(to)
            failover = CueHealth.Failover(from: from, to: to, reason: summary.title, at: now)
            outage = outage ?? .switched
            let why = summary.shownTitle.embedded
            guard let resets else { return ShownText("\(from.name) \(why)，我换到 \(to.name) 接着干。") }
            let at = resets.formatted(Calendar.current.isDateInToday(resets) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute())
            return ShownText("\(from.name) \(why)（\(at) 重置），我换到 \(to.name) 接着干。")
        } catch {
            Self.log.error("Cue 没能换大脑：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `attempt`（慢速周期到点）时轮到碰运气的那家也换。换了返回 true：下一次对账按它换大脑。
    func steer(attempt: Bool = false, at now: Date) async -> Bool {
        guard var detour else { return false }
        do {
            let lapsed = Set(detour.stuck.filter { $0.value.resets.map { $0 <= now } == true }.keys)
            if !lapsed.isEmpty {
                lapsed.forEach { detour.stuck[$0] = nil }
                self.detour = detour
            }
            let home = try await store.cueProfile()?.runtime.known
            let kinds = try await store.macAgents(on: setup.recorder.hostID).kinds
            guard let (to, open) = detour.next(from: detour.to, home: home, among: kinds, at: now) else { return false }
            // 卡着的那件不等慢速周期，马上在该能用的那家上重来
            if open, to != detour.to || lapsed.contains(to) { for held in setbacks where held.stuck { edit(held.wake) { $0.due(now) } } }
            guard to != detour.to, open || attempt else { return false }
            use(to)
            return true
        } catch {
            Self.log.error("Cue 没能换大脑：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func use(_ kind: AgentKind) {
        detour?.to = kind
        Self.log.notice("Cue 换大脑到 \(kind.rawValue, privacy: .public)")
    }

    func markDown() {
        guard let kind = brainSettings?.runtime.known, var detour else { return }
        detour.stuck[kind] = Detour.Stuck(at: now, resets: detour.stuck[kind]?.resets)
        self.detour = detour
    }

    /// 读不到（或已过）为 nil。
    private func resetsAt(_ agent: MacAgent?, kind: AgentKind, model: String?) async -> Date? {
        guard let agent,
              let option = model.flatMap(kind.modelKey).flatMap({ key in agent.models.first { $0.key == key } }) ?? agent.defaultModel,
              let quotas = try? await store.accountQuotas(on: setup.recorder.hostID),
              let quota = option.quota(in: quotas)
        else { return nil }
        let now = self.now
        return quota.binding(at: now, model: option.key.id).map(\.resetsAt).flatMap { $0 > now ? $0 : nil }
    }


    func tellDown(_ reason: ShownText) async {
        guard outage != .down else { return }
        outage = .down
        await say(.cue, ShownText("我起不来了：\(reason.embedded)\n我隔一阵会自己再试；你发条消息，我马上再试。"), urgent: true)
    }

    /// 一轮好好做完才调。`resolved`：卡着的那件也做完了。用回你设定的那家就不再绕行；还在别家就只记着你设定的那家卡着（等它的重置时刻换回）。
    func recovered(_ resolved: Bool) async {
        let kind = brainSettings?.runtime.known
        if let detour, let kind {
            do {
                let home = try await store.cueProfile()?.runtime.known
                self.detour = kind == home ? nil : Detour(to: kind, stuck: detour.stuck.filter { $0.key == home })
            } catch {
                Self.log.error("Cue 读设置失败，绕行照旧：\(error.localizedDescription, privacy: .public)")
            }
        }
        guard resolved, outage != nil, let kind else { return }
        outage = nil
        await say(.cue, ShownText("又能干活了，用的是 \(kind.name)。"))
    }


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

    /// 文件不在，读的那边就是“不在这台值班”。
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
