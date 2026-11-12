#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueText
import Foundation

extension CueKeeper {
    /// 一次对账只认一个此刻（开始时取）：到没到点、下一次排在哪都按它判断。对账途中才过的时刻照样排上，排成马上（`schedule` 不早于真实的此刻）；
    /// 否则过点的那一下两头落空：判断时还没到，排定时器时已过、不再排（如绕行的重置时刻，`Detour.nextReset`），要等别的动静才补上。
    func reconcile() async {
        timer?.cancel()
        timer = nil
        let now = self.now
        await revive(at: now)
        await giveBack([])  // 上次没退回成的再退一次
        await leaveHisStops()
        let next = await step(at: now)
        schedule([next, alarm(at: now)].compactMap(\.self).min())
    }

    /// 对账里按先后只做一件事；返回歇着时下一次要对账的时刻。
    private func step(at now: Date) async -> Date? {
        if await steer(at: now) {
            input.yield(.kick)
            return nil
        }
        do {
            let store = self.store
            let profile = try await store.cueProfile() ?? CueProfile()
            await follow(BrainSettings(profile))
            // 在交你的话之前：退回的话（含插进刚收尾那一轮、还没被接走的，`retire`）要交给新的大脑，你改过规矩之后的话按新规矩答
            if let shift, shift.turn == nil, try await outworn(shift) {
                Self.log.notice("Cue 换个班次（\(shift.retiring ? "这个大脑不能接着用" : "重点变了", privacy: .public)）")
                await retire(shift)
                await startShift()
                input.yield(.kick)
                return nil
            }
            let pending = ready(try await store.cueMessagesToDeliver())
            if !pending.isEmpty {
                if case .restarting(let failures, _, _) = phase { await startShift(failures: failures) }
                guard let shift else { return nil }
                let ids = pending.map(\.id)
                let said = CueEnvelope.delivered(pending, setAside: try await store.cueQuestionsSetAside(), files: store.files, imagesAsFiles: !shift.brain.seesImages)
                let images = await images(in: pending, for: shift.brain)
                // 插给在跑的那一轮就接在话后面（同一种写法）
                let related = try await CueTools(store: store).related(to: CueEnvelope.asked(pending))
                if shift.turn != nil {
                    let text = related.isEmpty ? said : said + "\n\n" + CueEnvelope.related(related).joined(separator: "\n")
                    guard await interject(text, images: images, delivering: ids) else { return nil }
                    try await markDelivered(ids)
                } else {
                    _ = try await wakeUp(.message, said: said, related: related, images: images, delivering: ids)
                }
                return nil
            }
            guard let shift, shift.turn == nil else { return nil }

            if brainSettings?.needsNewBrain(for: BrainSettings(profile)) == true {
                await retire(shift)
                await startShift()
                input.yield(.kick)
                return nil
            }

            if progress.greeted != profile.enabledAt {
                progress.greeted = profile.enabledAt
                guard try await handsEmpty() else {
                    _ = try await wakeUp(.enabled)
                    return nil
                }
                save()
            }

            let due = try await store.dueCueSchedules(at: now)
            // 持续重试只有一项承接中的工作；新定时留在库里，等它成功后再交付和消费。
            if setback?.persistent != true, !due.isEmpty {
                let fires = due.compactMap { line in
                    line.remindAt.map { CueFire(line: line.id, due: line.repeats?.latest(from: $0, until: now) ?? $0) }
                }
                guard try await wakeUp(.schedule(fires)) else { return nil }
                try await store.fireCueSchedules(due, at: now)
                return nil
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueSchedule(after: now) { deadlines.append(next) }
            // 等子代理停住不写库：到点由定时器叫醒对账
            if let stall = try await store.nextCueStall(after: now) { deadlines.append(stall) }

            // 额度、登录卡住的持续重试只按慢速周期重交原来的醒来原因（新变化不替代它、不催它：卡着时重来只会再失败），变化随信封一起看；
            // 到点时先按绕行的规则换到这一周期要试的那家（`steer`），新大脑起好再来。重来的那一轮半路断了（`broke`）也还在：到点的时刻留着，起好就再来
            if let held = setback, held.persistent {
                guard let at = held.retryAt, now >= at else { return held.retryAt }
                if await steer(attempt: true, at: now) {
                    input.yield(.kick)
                    return nil
                }
                _ = try await wakeUp(held.wake, as: held.author)
                return nil
            }
            let changes = try await self.changes(at: now)
            if let held = setback {
                // 等子代理停住只按时刻认新旧：它的序号是会话记录的，会话处理交回、又回到等子代理时也会变
                let fresh = changes.contains { $0.kind == .stalled ? $0.at > held.since : $0.seq > held.latest ?? Int.min }
                if fresh {
                    setback = nil
                } else if held.retryAt.map({ now >= $0 }) == true {
                    setback?.retryAt = nil
                    _ = try await wakeUp(held.wake, as: held.author)
                    return nil
                } else {
                    return [deadlines.min(), held.retryAt].compactMap(\.self).min()
                }
            }
            if !changes.isEmpty {
                _ = try await wakeUp(.sessionActivity(changes.map(CueStir.init)))
                return nil
            }

            let idleSince = try await store.cueLastYou()?.said ?? profile.enabledAt ?? shift.startedAt
            if try await !store.cueBoardActive(), let due = patrolDue(idleSince: idleSince, lastRequest: shift.lastRequest, now: now),
               try await !handsEmpty() {
                if due.at <= now {
                    let today = Self.day(now)
                    progress.patrols = (progress.patrolDay == today ? progress.patrols : 0) + 1
                    progress.patrolDay = today
                    if due.warm { progress.warmedIdle = idleSince } else { progress.patrolledIdle = idleSince }
                    _ = try await wakeUp(.idle)
                    return nil
                }
                deadlines.append(due.at)
            }
            return deadlines.min()
        } catch {
            Self.log.error("Cue 对账失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 规矩一变下一轮就换，不等换新：照旧的系统提示接着跑，他刚立的规矩要到缓存过期才生效，这之间 Cue 会照旧规矩动手；重点很少变，换一次的开销可以不计。
    private func outworn(_ shift: Shift) async throws -> Bool {
        if shift.retiring { return true }
        return try await CueMemoryView(store.cueMemory()).pinned.map(\.id) != shift.pinned
    }

    /// 把你的话插给以为在跑的那一轮（唯一的插话路径）。那一轮可能正好收尾、由下一轮接走：
    /// 哪一轮接走只按大脑报的 `TurnEvent.received`，接走你的话（`delivering`）的那一轮才回答你。
    /// 重点不经这里：一轮中途插规矩，模型会回应那句插话、盖掉这一轮给你的回复；规矩只在换班次时随系统提示生效（`outworn`）。
    /// 插不进去按大脑出了问题处理，返回 false。
    private func interject(_ text: String, images: [MessageImage], delivering ids: [UUID]) async -> Bool {
        guard let shift else { return false }
        let sending = UUID()
        do {
            try await shift.brain.send(text, images: images, id: sending)
        } catch {
            await broke(ShownText("发不进去：\(ShownText(error).embedded)"))
            return false
        }
        updateShift {
            $0.handed[sending] = ids
            $0.turn?.round.sent.append(text)
        }
        return true
    }

    /// 留了就立即上传：手机上马上进等你。
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

    /// 刚启用与空闲巡视手上什么都没有时都不醒：醒来只能说一句没有事，在 Cue 页留下一行什么都没做的记录。
    private func handsEmpty() async throws -> Bool {
        let board = try await store.cueBoard()
        guard board.tasks.isEmpty, board.sessions.isEmpty else { return false }
        return try await store.cueMessagesWaitingForYou().isEmpty
    }

    /// 热的赶在缓存过期前（`CueTiming.warmPatrolAfter`），冷的照空闲时长；两种每段空闲各至多一次、共用每天的次数，冷巡视过的这段空闲不再热巡视（冷巡视自己把缓存焐热了）。
    /// 都巡视过了、整天都是打扰时段为 nil。
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
