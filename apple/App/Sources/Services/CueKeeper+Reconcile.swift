#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueText
import Foundation

extension CueKeeper {
    func reconcile() async {
        timer?.cancel()
        timer = nil
        let now = self.now
        await revive(at: now)
        await claimUnanswered()
        await giveBack([])
        await recordFires()
        await leaveHisStops()
        let next = await step(at: now)
        schedule([next, alarm(at: now)].compactMap(\.self).min())
    }

    private func step(at now: Date) async -> Date? {
        if await steer(at: now) {
            input.yield(.kick)
            return nil
        }
        do {
            let store = self.store
            let (profile, waiting) = try store.snapshot { (try $0.cueProfile() ?? CueProfile(), try $0.cueMessagesToDeliver()) }.value
            await follow(BrainSettings(profile, detour))
            if let shift, shift.turn == nil, try await outworn(shift) || brainSettings?.needsNewBrain(for: BrainSettings(profile, detour)) == true {
                Self.log.notice("Cue 换个班次（\(shift.retiring ? "这个大脑不能接着用" : "重点或设置变了", privacy: .public)）")
                await retire(shift)
                await startShift()
                input.yield(.kick)
                return nil
            }
            if waiting.isEmpty { setbacks.removeAll { $0.wake == .message } }
            let gate = setbacks.first { $0.wake == .message }
            let pending = ready(waiting)
            if !pending.isEmpty, gate.map({ gate in gate.retryAt.map { now >= $0 } != false || pending.contains { !gate.held.contains($0.id) } }) ?? true {
                if case .restarting(let failures, _, _) = phase { await startShift(failures: failures) }
                if gate?.stuck == true, shift?.turn == nil, await steer(attempt: true, at: now) {
                    input.yield(.kick)
                    return nil
                }
                guard let shift else { return nil }
                let ids = pending.map(\.id)
                let said = CueEnvelope.delivered(pending, setAside: try await store.cueQuestionsSetAside(), files: store.files, imagesAsFiles: !shift.brain.seesImages)
                let images = await images(in: pending, for: shift.brain)
                let related = try await CueTools(store: store).related(to: CueEnvelope.asked(pending))
                if shift.turn != nil {
                    let text = related.isEmpty ? said : said + "\n\n" + CueEnvelope.related(related).joined(separator: "\n")
                    try await interject(text, images: images, delivering: ids)
                } else {
                    _ = try await wakeUp(.message, said: said, related: related, images: images, delivering: ids)
                }
                return nil
            }
            guard let shift, shift.turn == nil else { return nil }

            if progress.greeted != profile.enabledAt, !setbacks.contains(where: { $0.wake == .enabled }) {
                if try await handsEmpty() {
                    progress.greeted = profile.enabledAt
                    save()
                } else {
                    greeting = profile.enabledAt
                    _ = try await wakeUp(.enabled)
                    return nil
                }
            }

            let due = try await store.dueCueSchedules(at: now)
            forgetSetbacks(outside: Set(due.map(\.id)))
            let untried = due.filter { line in !unfired.contains { $0.line == line.id } && !setbacks.contains { $0.wake.fires.contains { $0.line == line.id } } }
            if !stuck, !untried.isEmpty {
                let fires = untried.compactMap { line in
                    line.remindAt.map { CueFire(line: line.id, due: line.repeats?.latest(from: $0, until: now) ?? $0) }
                }
                _ = try await wakeUp(.schedule(fires))
                return nil
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueSchedule(after: now) { deadlines.append(next) }
            if let stall = try await store.nextCueStall(after: now) { deadlines.append(stall) }

            if stuck, let held = setback {
                guard let at = held.retryAt, now >= at, held.wake != .message else { return held.retryAt.flatMap { $0 > now ? $0 : nil } }
                if await steer(attempt: true, at: now) {
                    input.yield(.kick)
                    return nil
                }
                _ = try await wakeUp(held.wake)
                return nil
            }
            let changes = try await self.changes(at: now)
            if let newest = setbacks.max(by: { $0.since < $1.since }) {
                func fresh(_ held: Setback) -> Bool {
                    changes.contains { change in
                        guard change.kind != .stalled, let latest = held.latest else { return change.at > held.since }
                        return change.seq > latest
                    }
                }
                if setbacks.contains(where: { $0.supersedable && fresh($0) }) { setbacks.removeAll { $0.supersedable && fresh($0) } }
                if let held = setback, held.wake != .message, held.retryAt.map({ now >= $0 }) == true {
                    if try await wakeUp(held.wake), held.supersedable { edit(held.wake) { $0.stage = .awaitingChange } }
                    return nil
                }
                if !fresh(newest) { return [deadlines.min(), setback?.retryAt].compactMap(\.self).min() }
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
            Self.log.error("Cue 对账失败，过一阵再对：\(error.localizedDescription, privacy: .public)")
            return now + setup.timing.retryWake.seconds
        }
    }

    private func claimUnanswered() async {
        guard !claimed else { return }
        do {
            owed.formUnion(Set(try await store.cueMessagesUnanswered()).subtracting(shift?.unanswered ?? []))
            claimed = true
        } catch {
            Self.log.error("Cue 读没答上的话失败，过一阵再读：\(error.localizedDescription, privacy: .public)")
        }
    }

    func recordFires() async {
        guard !unfired.isEmpty else { return }
        do {
            try await store.fireCueSchedules(unfired, at: now)
            unfired = []
        } catch {
            Self.log.error("Cue 做完的定时没能消费，过一阵再写：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func forgetSetbacks(outside due: Set<UUID>) {
        let kept: [Setback] = setbacks.compactMap { held in
            guard case .schedule(let fires) = held.wake else { return held }
            let owed = fires.filter { due.contains($0.line) }
            guard !owed.isEmpty else { return nil }
            var held = held
            held.wake = .schedule(owed)
            return held
        }
        if kept != setbacks { setbacks = kept }
    }

    private func outworn(_ shift: Shift) async throws -> Bool {
        if shift.retiring { return true }
        return try await CueMemoryView(store.cueMemory()).pinned.map(\.id) != shift.pinned
    }

    /// 把你的话插给以为在跑的那一轮（唯一的插话路径）。那一轮可能正好收尾、由下一轮接走：
    /// 哪一轮接走只按大脑报的 `TurnEvent.received`，接走你的话（`delivering`）的那一轮才回答你。
    /// 重点不经这里：一轮中途插规矩，模型会回应那句插话、盖掉这一轮给你的回复；规矩只在换班次时随系统提示生效（`outworn`）。
    /// 插不进去按大脑出了问题处理（`hand`）。
    private func interject(_ text: String, images: [MessageImage], delivering ids: [UUID]) async throws {
        guard try await hand(text, images: images, id: UUID(), delivering: ids) else { return }
        updateShift { $0.turn?.round.sent.append(text) }
    }

    private func leaveHisStops() async {
        guard let from = handedOver ?? progress.marks?.sessions else { return }
        do {
            handedOver = try await store.leaveHisStops(after: from)
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
                input.yield(.kick)
            } catch {
                do {
                    _ = try await store.updateCueProfile { [detour] profile in
                        guard BrainSettings(profile, detour) == wanted else { return }
                        if current.runtime == profile.runtime { profile.model = current.model }
                        profile.effort = current.effort.map(Open.known)
                    }
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

    private func handsEmpty() async throws -> Bool {
        let board = try await store.cueBoard()
        guard board.tasks.isEmpty, board.sessions.isEmpty else { return false }
        return try await store.cueMessagesWaitingForYou().isEmpty
    }

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
