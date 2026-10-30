#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation

extension CueKeeper {
    func reconcile() async {
        timer?.cancel()
        timer = nil
        await leaveHisStops()
        do {
            let store = self.store, now = Date.now
            let profile = try await store.cueProfile() ?? CueProfile()
            await follow(BrainSettings(profile))
            // 要换的班次（工具服务没了、换了 Agent），或该换新了、一直记着的又变过（系统提示跟上）：换个班次，再接着对账。
            // 在交你的话之前：退回的话要交给新的大脑
            if let shift, shift.turn == nil, try await outworn(shift, now: now) {
                Self.log.notice("Cue 换个班次（\(shift.retiring ? "这个大脑不能接着用" : "换新时一直记着的变了", privacy: .public)）")
                await shift.brain.stop()()
                await startShift()
                input.yield(.kick)
                return
            }
            let pending = ready(try await store.cueMessagesToDeliver())
            if !pending.isEmpty {
                if case .restarting(let failures, _, _) = phase { await startShift(failures: failures) }
                guard let shift else { return }
                let ids = pending.map(\.id)
                let said = CueEnvelope.delivered(pending, setAside: try await store.cueQuestionsSetAside(), files: store.files, imagesAsFiles: !shift.brain.seesImages)
                let images = await images(in: pending, for: shift.brain)
                if shift.turn != nil {
                    do {
                        try await shift.brain.send(said, images: images)
                    } catch {
                        return await broke(ShownText("发不进去：\(ShownText(error).embedded)"))
                    }
                    updateShift {
                        $0.turn?.author = .cue
                        $0.turn?.delivered += ids
                        $0.turn?.round.sent.append(said)
                    }
                    try await markDelivered(ids)
                } else {
                    _ = try await wakeUp(.message, said: said, images: images, delivering: ids)
                }
                return
            }
            guard let shift, shift.turn == nil else { return }

            if brainSettings?.needsNewBrain(for: BrainSettings(profile)) == true {
                await shift.brain.stop()()
                await startShift()
                input.yield(.kick)
                return
            }

            if progress.greeted != profile.enabledAt {
                progress.greeted = profile.enabledAt
                guard try await handsEmpty() else {
                    _ = try await wakeUp(.enabled)
                    return
                }
                save()
            }

            let due = try await store.dueCueSchedules(at: now)
            if !due.isEmpty {
                // 错过了几次的只补最近的那一次：本该几点记那一次
                let fires = due.compactMap { line in
                    line.remindAt.map { CueFire(line: line.id, due: line.repeats?.latest(from: $0, until: now) ?? $0) }
                }
                guard try await wakeUp(.schedule(fires)) else { return }
                try await store.fireCueSchedules(due, at: now)
                return
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueSchedule(after: now) { deadlines.append(next) }
            // 等子代理停住不写库：到点由定时器叫醒对账
            if let stall = try await store.nextCueStall(after: now) { deadlines.append(stall) }

            let changes = try await self.changes(at: now)
            // 出错之后：有新变化就是新事件，照常；没有就等重试的时刻，过了这一次就只等新变化。
            // 等着重来的是你的一轮（额度、登录卡住）：新变化不顶掉它，这就重来（变化随信封一起看）
            if let held = setback {
                let fresh = changes.due.contains(where: { $0.seq > held.latest ?? Int.min || ($0.kind == .stalled && $0.at > held.since) })
                if fresh, held.wake != .message {
                    setback = nil
                } else if fresh || held.retryAt.map({ now >= $0 }) == true {
                    setback?.retryAt = nil
                    return _ = try await wakeUp(held.wake, as: held.author)
                } else {
                    return schedule([deadlines.min(), held.retryAt].compactMap { $0 }.min())
                }
            }
            if !changes.due.isEmpty {
                return _ = try await wakeUp(.sessionActivity(changes.due.map(CueStir.init)))
            }
            // 没叫醒 Cue：他新在场的停下记下，不再记的划掉（叫醒的一轮做完才换）
            if changes.held != progress.held {
                progress.held = changes.held
                save()
            }
            if let lapse = changes.lapse { deadlines.append(lapse) }

            let idleSince = try await store.cueLastYou()?.said ?? profile.enabledAt ?? shift.startedAt
            if try await !store.cueBoardActive(), let due = patrolDue(idleSince: idleSince, lastRequest: shift.lastRequest, now: now),
               try await !handsEmpty() {
                if due.at <= now {
                    let today = Self.day(now)
                    progress.patrols = (progress.patrolDay == today ? progress.patrols : 0) + 1
                    progress.patrolDay = today
                    if due.warm { progress.warmedIdle = idleSince } else { progress.patrolledIdle = idleSince }
                    return _ = try await wakeUp(.idle)
                }
                deadlines.append(due.at)
            }
            schedule(deadlines.min())
        } catch {
            Self.log.error("Cue 对账失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 这个班次不接着用了：要换的（`Shift.retiring`），或该换新了、一直记着的又变过。
    private func outworn(_ shift: Shift, now: Date) async throws -> Bool {
        if shift.retiring { return true }
        guard shift.primed, renewDue(shift, now: now) else { return false }
        return try await CueMemoryView(store.cueMemory()).pinned.map(\.line.id) != shift.pinned
    }

    /// 他发起的一轮停下当场留给他回（`CueStore.leaveHisStops`），留了就立即上传：手机上马上进等你。
    private func leaveHisStops() async {
        guard let from = handedOver ?? progress.marks?.sessions else { return }
        do {
            let (mark, left) = try await store.leaveHisStops(after: from)
            handedOver = mark
            if let left { await setup.upload([left]) }
        } catch {
            Self.log.error("他那一轮的停下没能留给他回：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 设置与在用的不同：没在跑就按新设置起；在跑、空闲且只换模型或强度就地换（下一轮起生效），换时又改了的接着换。
    private func follow(_ wanted: BrainSettings) async {
        guard let current = brainSettings, wanted != current else { return }
        switch phase {
        case .restarting:
            await startShift()
        case .running(let shift) where shift.turn == nil && !current.needsNewBrain(for: wanted):
            do {
                try await shift.brain.configure(model: wanted.model, effort: wanted.effort)
                brainSettings = wanted
                Self.log.notice("Cue 就地换了模型或强度：\(Dotted(wanted.model ?? "默认", wanted.effort?.rawValue ?? "默认").visible, privacy: .public)")
                if let profile = try? await store.cueProfile() { await follow(BrainSettings(profile)) }
            } catch {
                // 大脑不认：设置改回在用的（选择器上看到的就是在用的），告诉你一声。
                // 等回应时你又改了设置就不动：你后来的选择照常生效，下一次对账再去对上
                var restored = wanted
                (restored.model, restored.effort) = (current.model, current.effort)
                do {
                    let profile = try await store.updateCueProfile { profile in
                        guard BrainSettings(profile) == wanted else { return }
                        (profile.model, profile.effort) = (current.model, current.effort.map(Open.known))
                    }
                    if BrainSettings(profile) == restored { await setup.upload([CueProfile.recordID]) }
                } catch {
                    Self.log.error("Cue 的设置没能改回在用的：\(error.localizedDescription, privacy: .public)")
                }
                let why = ShownText(error).embedded
                await say(.cue, wanted.model.map { ShownText("没换成 \($0)：\(why)\n我还用原来的。") } ?? ShownText("没换成：\(why)\n我还用原来的。"))
            }
        case .starting, .running:
            break
        }
    }

    /// 手上什么都没有：没做完的任务、不归它们的活会话（含出错、在等回答的）、等你的卡一样都没有。刚启用与空闲巡视这时都不醒：
    /// 醒来只能说一句没有事，在 Cue 页留下一行什么都没做的记录。
    private func handsEmpty() async throws -> Bool {
        let board = try await store.cueBoard()
        guard board.tasks.isEmpty, board.sessions.isEmpty else { return false }
        return try await store.cueMessagesWaitingForYou().isEmpty
    }

    /// 下一次巡视（`warm` 是热巡视），两种里早的那个：热的赶在缓存过期前（`CueTiming.warmPatrolAfter`），冷的照空闲时长；两种每段空闲各至多一次、
    /// 共用每天的次数，冷巡视过的这段空闲不再热巡视（冷巡视自己把缓存焐热了）。都巡视过了、整天都是打扰时段为 nil；今天次数用完等到明天（冷的）。
    private func patrolDue(idleSince: Date, lastRequest: Date?, now: Date) -> (at: Date, warm: Bool)? {
        let timing = setup.timing
        let used = progress.patrolDay == Self.day(now) ? progress.patrols : 0
        let cold = progress.patrolledIdle == idleSince ? nil : timing.awake(from: used < Self.patrolsPerDay
            ? max(now, idleSince + timing.patrolAfter.seconds)
            : Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600))
        var warm: Date?
        if used < Self.patrolsPerDay, progress.warmedIdle != idleSince, progress.patrolledIdle != idleSince, let lastRequest,
           let at = timing.awake(from: max(now, idleSince + timing.warmPatrolAfter.seconds)),
           at <= lastRequest + (timing.cacheLifetime - timing.cacheMargin).seconds {
            warm = at
        }
        if let warm, cold.map({ warm < $0 }) ?? true { return (warm, true) }
        return cold.map { ($0, false) }
    }
}
#endif
