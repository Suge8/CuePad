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
        do {
            let store = self.store, now = Date.now
            let profile = try await store.cueProfile() ?? CueProfile()
            await follow(BrainSettings(profile))
            // 该换新了、一直记着的又变过：换个班次（系统提示跟上），再接着对账
            if let shift, shift.turn == nil, shift.primed, renewDue(shift, now: now),
               try await CueMemoryView(store.cueMemory()).pinned.map(\.line.id) != shift.pinned {
                Self.log.notice("Cue 换新时一直记着的变了：换个班次")
                await shift.brain.stop()()
                await startShift()
                input.yield(.kick)
                return
            }
            let pending = try await store.cueMessagesToDeliver()
            if !pending.isEmpty {
                if case .stuck = phase { await startShift() }
                guard let shift else { return }
                let ids = pending.map(\.id)
                let said = CueEnvelope.delivered(pending, setAside: try await store.cueQuestionsSetAside())
                let images = await images(in: pending, for: shift.brain)
                if shift.turn != nil {
                    do {
                        try await shift.brain.send(said, images: images)
                    } catch {
                        return await broke(String(localized: "发不进去：\(error.localizedDescription)"))
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

            let due = try await store.dueCueReminders(at: now)
            if !due.isEmpty {
                guard try await wakeUp(.reminder(due.map(\.id))) else { return }
                for line in due { try await store.clearCueReminder(line.id) }
                return
            }
            var deadlines: [Date] = []
            if let next = try await store.nextCueReminder(after: now) { deadlines.append(next) }
            // 等子代理停住不写库：到点由定时器叫醒对账
            if let stall = try await store.nextCueStall(after: now) { deadlines.append(stall) }

            let changes = try await self.changes(at: now)
            // 出错之后：有新变化就是新事件，照常；没有就等重试的时刻，过了这一次就只等新变化
            if let held = setback {
                if changes.due.contains(where: { $0.seq > held.latest ?? Int.min || ($0.kind == .stalled && $0.at > held.since) }) {
                    setback = nil
                } else if let retryAt = held.retryAt, now >= retryAt {
                    setback?.retryAt = nil
                    return _ = try await wakeUp(held.wake, as: held.author)
                } else {
                    return schedule([deadlines.min(), held.retryAt].compactMap { $0 }.min())
                }
            }
            if !changes.due.isEmpty {
                return _ = try await wakeUp(.sessionActivity(changes.due.map(CueStir.init)))
            }
            // 没叫醒 Cue：新归他的记下，不再归他的划掉（叫醒的一轮做完才换）
            if changes.held != progress.held {
                progress.held = changes.held
                save()
            }
            if let lapse = changes.lapse { deadlines.append(lapse) }

            let idleSince = try await store.cueLastYou()?.said ?? profile.enabledAt ?? shift.startedAt
            if try await !store.cueBoardActive(), let due = patrolDue(idleSince: idleSince, now: now), try await !handsEmpty() {
                if due <= now {
                    let today = Self.day(now)
                    progress.patrols = (progress.patrolDay == today ? progress.patrols : 0) + 1
                    progress.patrolDay = today
                    progress.patrolledIdle = idleSince
                    return _ = try await wakeUp(.idle)
                }
                deadlines.append(due)
            }
            schedule(deadlines.min())
        } catch {
            Self.log.error("Cue 对账失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 设置与在用的不同：没在跑就按新设置起；在跑、空闲且只换模型或强度就地换（下一轮起生效），换时又改了的接着换。
    private func follow(_ wanted: BrainSettings) async {
        guard let current = brainSettings, wanted != current else { return }
        switch phase {
        case .restarting, .stuck:
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
                let why = error.localizedDescription
                await say(.cue, wanted.model.map { String(localized: "没换成 \($0)：\(why)\n我还用原来的。") } ?? String(localized: "没换成：\(why)\n我还用原来的。"))
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

    /// 什么时候可以巡视；这段空闲巡视过了、今天次数用完（等到明天）、整天都是打扰时段为 nil。
    private func patrolDue(idleSince: Date, now: Date) -> Date? {
        guard progress.patrolledIdle != idleSince else { return nil }
        let today = Self.day(now)
        let used = progress.patrolDay == today ? progress.patrols : 0
        let earliest = used < Self.patrolsPerDay
            ? max(now, idleSince + setup.timing.patrolAfter.seconds)
            : Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return setup.timing.awake(from: earliest)
    }
}
#endif
