#if os(macOS)
import CueAgent
import CuePi
import CueStore
import Foundation

/// 出了问题怎么自己接着干：看门狗、额度登录卡住时换大脑（绕行）、起不来与恢复时说的话、大脑健康的本机投影（`CueHealth`）。
///
/// 绕行：额度、登录卡住时用哪家只有一条规则（`Detour.next`），卡住当场（`failOver`）、每次对账（`steer`）、慢速周期到点都按它：
/// - 卡住的那家记进绕行（读得到就带重置时刻）；换过去的那家起不来（快的重试用完）也算卡住。绕行记着你设定的那家与它的模型、强度、fast。
/// - 你设定的那家没卡住或重置已过就用它（原模型、强度）；否则此刻用的那家没卡住就留它（哪家好好做完一轮就留哪家）；否则没卡过的那家；
///   否则重置已过的里最早的。这几种该能用，马上换：卡住当场换过去，你设定的那家重置时刻一到就换回（对账的定时器排这一刻）。
///   重置已过的不再算卡住；换到该能用的那家或这家重置刚过，卡着的那件马上在它上面重来，不等慢速周期（只有这一家时也是）。
/// - 都不是（试过的都卡着、重置没过或读不到）：轮到最近卡住的那家后面的一家，只在慢速周期到点（重来那一轮、重起大脑）时换，每个周期只试一家。
/// - 一轮好好做完：那家不再算卡住，别的卡住记录清掉（你设定的那家的留着，等它的重置时刻）；它就是你设定的那家，绕行结束。
///   你或 Cue（`setup set`）改了设置也结束：后来的选择就是你设定的。
/// 说的话：卡住当场换过去说一句从哪换到哪；没得换时那个错只说一次，慢速周期里换着家重来不再说；换过去的那一家起不来照样说一次起不来；
/// 不论换没换家，好好做完卡着的那件的一轮说一句恢复了、用的哪家（`recovered`）。
/// 取舍：换回只认读得到的重置时刻，不为探你设定的那家好没好而反复换大脑（每换一次丢一次会话与提示缓存）；读不到的（登录）留在能用的那家，换回由你或 Cue 定。
extension CueKeeper {
    // MARK: 重起与看门狗

    /// 大脑这时该有人管的那一下（对账的定时器排它，`reconcile`）：等着重起的到点时刻，或在跑的一轮还差多久没动静满 `CueTiming.silence`（看门狗）。
    /// 定时器照墙钟睡，睡着的 Mac 醒来时它先到点：看门狗按醒着的时长再算一次（`revive`），没满就按剩下的重排。
    /// 另有两种也排在这里：你的话退回没写成时隔一阵再试（`giveBack`），绕行里下一个重置时刻（到点换回该能用的那家，`steer`）。
    func alarm(at now: Date) -> Date? {
        let brain: Date? = switch phase {
        case .restarting(_, _, let at): at
        case .running(let shift) where shift.turn != nil: now + (setup.timing.silence - quiet).seconds
        case .starting, .running: nil
        }
        let retry = owed.isEmpty ? nil : now + setup.timing.returnRetry.seconds
        return [brain, retry, progress.detour?.nextReset(after: now)].compactMap(\.self).min()
    }

    /// 在跑的这一轮醒着的时间里多久没有大脑事件（Mac 睡着的那段不算，`CueTiming.awake`）。
    private var quiet: Duration { setup.timing.awake() - heardAt }

    /// 到了 `alarm`：等着重起的起一个；在跑的一轮醒着那么久没动静就当大脑挂了（停掉，按 `broke` 重起、交出去的话重新交）。
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

    /// 工具结果说 Cue 的工具服务（`cuepad mcp`）没了（Pi 的接入 `cue-tools.ts` 报的）：这个班次的工具用不了了，做完这一轮就换。
    static func toolsDown(_ result: String) -> Bool { result.contains(/CuePad 的工具服务.*(退出了|没有回应)/) }

    // MARK: 绕行

    /// 额度、登录卡住（`PiFailure.retries` 为假）：这家记进绕行（头注释）；有该能用的另一家就把设置换过去，返回告诉你的那句
    /// （从哪换到哪、为什么、额度读得到就带重置时刻）。没有为 nil：照常报错，慢速周期到点再换着试（`steer`）。
    func failOver(_ failure: String) async -> ShownText? {
        let summary = PiErrorSummary(failure)
        guard !summary.failure.retries, let settings = brainSettings, let from = settings.runtime.known else { return nil }
        let now = self.now
        do {
            let agents = try await store.macAgents(on: setup.recorder.hostID)
            let resets = await resetsAt(agents.agent(from), kind: from, model: settings.model)
            var detour = progress.detour ?? Detour(settings, from: from)
            detour.stuck[from] = Detour.Stuck(at: now, resets: resets)
            progress.detour = detour
            save()
            guard let (to, open) = detour.next(from: from, among: agents.kinds, at: now), open, to != from else { return nil }
            try await switchBrain(to)
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

    /// 绕行时让设置跟上规则（`Detour.next`）：你或 Cue 改过设置就不再绕行；该能用的那家（你设定的那家重置已过……）马上换过去；
    /// `attempt`（慢速周期到点：重来那一轮、重起大脑）时轮到碰运气的那家也换。改了设置返回 true：下一次对账按新设置换大脑。
    func steer(attempt: Bool = false, at now: Date) async -> Bool {
        guard var detour = progress.detour else { return false }
        do {
            guard let profile = try await store.cueProfile(), let current = profile.runtime.known, detour.wrote(profile) else {
                progress.detour = nil
                save()
                return false
            }
            // 重置已过的不再算卡住：在它上面再试，又卡住时重新记下（`failOver`）
            let lapsed = Set(detour.stuck.filter { $0.value.resets.map { $0 <= now } == true }.keys)
            if !lapsed.isEmpty {
                lapsed.forEach { detour.stuck[$0] = nil }
                progress.detour = detour
                save()
            }
            let kinds = try await store.macAgents(on: setup.recorder.hostID).kinds
            guard let (to, open) = detour.next(from: current, among: kinds, at: now) else { return false }
            // 该能用的那家（换过去的，或重置刚过的这家）：卡着的那件不等慢速周期，马上在它上面重来
            if open, to != current || lapsed.contains(to), setback?.persistent == true { setback?.retryAt = now }
            guard to != current, open || attempt else { return false }
            try await switchBrain(to)
            return true
        } catch {
            Self.log.error("Cue 没能换大脑：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 设置换到这家（`Detour.apply`），立即上传。
    private func switchBrain(_ kind: AgentKind) async throws {
        guard let detour = progress.detour else { return }
        _ = try await store.updateCueProfile { detour.apply(kind, to: &$0) }
        await setup.upload([CueProfile.recordID])
        Self.log.notice("Cue 换大脑到 \(kind.rawValue, privacy: .public)")
    }

    /// 起不来（快的重试用完）的是绕行换过去的那家：也算卡住（读不到重置），慢速周期到点轮到下一家。
    func markDown() {
        guard let kind = brainSettings?.runtime.known, var detour = progress.detour else { return }
        detour.stuck[kind] = Detour.Stuck(at: now, resets: detour.stuck[kind]?.resets)
        progress.detour = detour
        save()
    }

    /// 那家在用的模型（没指定是它的默认）关联的额度此刻卡着的窗口何时重置；读不到（或已过）为 nil。
    private func resetsAt(_ agent: MacAgent?, kind: AgentKind, model: String?) async -> Date? {
        guard let agent,
              let option = model.flatMap(kind.modelKey).flatMap({ key in agent.models.first { $0.key == key } }) ?? agent.defaultModel,
              let quotas = try? await store.accountQuotas(on: setup.recorder.hostID),
              let quota = option.quota(in: quotas)
        else { return nil }
        let now = self.now
        return quota.binding(at: now, model: option.key.id).map(\.resetsAt).flatMap { $0 > now ? $0 : nil }
    }

    // MARK: 起不来与恢复

    /// 快的重试用完、要转慢的了：这次故障里说一次起不来（提示你），之后不再说，恢复时说一句（`recovered`）。绕行换过去的那家起不来也算卡住（`markDown`）。
    func tellDown(_ reason: ShownText) async {
        guard outage != .down else { return }
        outage = .down
        await say(.cue, ShownText("我起不来了：\(reason.embedded)\n我隔一阵会自己再试；你发条消息，我马上再试。"), urgent: true)
    }

    /// 一轮好好做完：这家能用，绕行里留它（不再算卡住，别的卡住记录清掉，你设定的那家的留着等重置）；它就是你设定的那家，绕行结束。
    /// `resolved`（卡着的那件也做完了）且这次故障告诉过你（换了家、起不来、卡住，`outage`）：说一句恢复了、用的哪家，这次故障里只说这一句；
    /// 起好又挂、反复起不来的都不算。
    func recovered(_ resolved: Bool) async {
        let kind = brainSettings?.runtime.known
        if let detour = progress.detour, let kind {
            var kept = detour
            kept.stuck = detour.stuck.filter { $0.key == detour.runtime && $0.key != kind }
            let next = kind == detour.runtime ? nil : kept
            if next != detour {
                progress.detour = next
                save()
            }
        }
        guard resolved, outage != nil, let kind else { return }
        outage = nil
        await say(.cue, ShownText("又能干活了，用的是 \(kind.name)。"))
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
