#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueText
import Foundation

extension CueKeeper {
    var shift: Shift? {
        if case .running(let shift) = phase { shift } else { nil }
    }

    var turn: Turn? { shift?.turn }

    func updateShift(_ edit: (inout Shift) -> Void) {
        guard case .running(var shift) = phase else { return }
        edit(&shift)
        phase = .running(shift)
    }

    func startShift(failures: Int = 0) async {
        phase = .starting(failures: failures)
        do {
            let profile = try await store.cueProfile() ?? CueProfile()
            let settings = BrainSettings(profile, detour)
            brainSettings = settings
            guard let runtime = settings.runtime.known, let launch = try await setup.launch(runtime) else {
                return await broke(ShownText("这台 Mac 上没有找到 \(settings.runtime.rawValue)"))
            }
            let memory = CueMemoryView(try await store.cueMemory())
            let brain = try await startBrain(
                runtime, launch, model: settings.model, effort: settings.effort, fast: settings.fast,
                systemPrompt: CuePrompt.system(name: profile.name, memory: memory, agents: launch.agents, runtime: runtime, interface: .current),
                tools: ["--wait", "\(setup.timing.sayWait)"])
            shifts += 1
            let id = shifts, input = input
            phase = .running(Shift(
                id: id, brain: brain, pinned: memory.pinned.map(\.id), startedAt: now, failures: failures))
            Task { for await event in brain.events { input.yield(.brain(id, event)) } }
            Self.log.notice("Cue 第 \(id) 个班次开始（\(runtime.rawValue, privacy: .public)）")
        } catch {
            await broke(ShownText(error))
        }
    }

    func startBrain(
        _ runtime: AgentKind, _ launch: CueLaunch, model: String?, effort: ThinkingLevel?, fast: Bool = false, systemPrompt: String, tools: [String]
    ) async throws -> any HostedSession {
        let work = setup.directory.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try await CueBrainConfig(
            runtime: runtime, executable: launch.executable, model: model, effort: effort, fast: fast, systemPrompt: systemPrompt, workingDirectory: work,
            mcp: [setup.helper.path, "mcp"] + tools,
            environment: ["CUEPAD_LIBRARY_DIR": setup.library.path, AgentKind.pi.facts.homeVariable: setup.piAgentDirectory.path, "PATH": launch.path],
            timing: store.timing
        ).startBrain()
    }

    func broke(_ reason: ShownText) async {
        Self.log.error("Cue 的大脑出了问题：\(reason.text, privacy: .public)")
        trouble = CueHealth.Failure(at: now, text: reason.text)
        let failures: Int
        switch phase {
        case .starting(let before): failures = before + 1
        case .running(let shift):
            if let turn = shift.turn {
                var round = turn.round
                round.failure = round.failure ?? reason.text
                archive(round)
                retrying = round.failure
                if let woke = turn.selfStarted, !Setback.supersedable(woke) { await setBack(reason.text, retrying: woke) }
            }
            await retire(shift)
            speech.offer(nil)
            failures = shift.failures + 1
        case .restarting: return
        }
        if let switched = await failOver(reason.text) {
            phase = .restarting(failures: 0, reason: reason, at: now)
            return await say(.cue, switched)
        }
        phase = .restarting(failures: failures, reason: reason, at: now + setup.timing.restartDelay(after: failures).seconds)
        guard setup.timing.isDown(after: failures) else { return }
        markDown()
        await tellDown(reason)
    }

    func retire(_ shift: Shift) async {
        await shift.brain.stop()()
        updateShift { shift in
            (shift.handed, shift.taken) = ([:], [])
            shift.turn?.delivered = []
        }
        await giveBack(shift.unanswered)
    }

    func handle(_ event: TurnEvent) async {
        switch event {
        case .speaking, .context: break
        default: Self.log.info("Cue 的大脑：\(String(describing: event).prefix(200), privacy: .private)")
        }
        heardAt = setup.timing.awake()
        switch event {
        case .turnStarted:
            speech.offer(nil)
            if turn == nil {
                let round = beginRound(.message, sent: [], at: now)
                updateShift {
                    $0.turn = Turn(answersYou: true, round: round, delivered: $0.taken)
                    $0.taken = []
                }
            }
        case .received(let id):
            updateShift { shift in
                guard let ids = shift.handed.removeValue(forKey: id), !ids.isEmpty else { return }
                guard shift.turn != nil else { return shift.taken += ids }
                shift.turn?.answersYou = true
                shift.turn?.delivered += ids
            }
        case .speaking(let draft):
            updateShift { $0.turn?.speaking = draft }
            speech.offer(turn?.answersYou == true ? draft : nil)
        case .context(let used, _):
            updateShift {
                $0.context = CueContext(used: used)
                $0.lastRequest = now
            }
        case .tool(let id, let name, let arguments): await began(id, name, arguments)
        case .toolDone(let id, let result, let failed): await ended(id, result: result, failed: failed)
        case .failed(let raw):
            updateShift { $0.turn?.round.failure = raw }
            trouble = CueHealth.Failure(at: now, text: raw)
            if let switched = await failOver(raw) {
                updateShift {
                    $0.retiring = true
                    $0.turn?.replay = true
                }
                if let turn, turn.answersYou { await reply(switched, in: turn) } else { await say(.cue, switched) }
                return
            }
            let summary = ErrorSummary(raw)
            if let woke = turn?.selfStarted, firstError(woke), Self.retryable(summary) { return }
            guard !stuck, summary.line != toldFailure else { return }
            toldFailure = summary.line
            if !Self.retryable(summary) { outage = .down }
            let text = summary.kind == .other ? ShownText("这一轮出错了：\(raw)") : ShownText("这一轮出错了：\(summary.shownTitle.embedded)\n\(raw)")
            if let turn, turn.answersYou { await reply(text, in: turn) } else { await say(.cue, text) }
        case .turnFinished:
            await leaveUnattended()
            guard var finished = turn else { return }
            let reply = finished.writesReply ? finished.speaking?.text : nil
            if reply?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { toldFailure = nil }
            let retried = finished.round.failure.map { finished.replay || finished.selfStarted != nil || !Self.retryable(ErrorSummary($0)) } ?? false
            do {
                finished.round.row = try await finish(finished, reply: reply, answered: !retried)
            } catch {
                Self.log.error("Cue 这一轮的收尾没能写进资料库：\(error.localizedDescription, privacy: .public)")
                await giveBack(finished.delivered)
            }
            archive(finished.round)
            updateShift {
                $0.turn = nil
                $0.failures = 0
            }
            if let failure = finished.round.failure {
                if finished.replay {
                    await replay(finished, failure: failure)
                } else if retried {
                    if let woke = finished.selfStarted { await setBack(failure, retrying: woke) }
                    if !finished.delivered.isEmpty { await setBack(failure, retrying: .message, holding: finished.delivered) }
                    await giveBack(finished.delivered)
                }
            } else {
                setbacks = setbacks.filter { $0.wake != finished.round.wake && ($0.stuck || !$0.supersedable) }.map { held in
                    var held = held
                    held.due(now)
                    return held
                }
                if case .schedule(let fires) = finished.selfStarted {
                    unfired += fires
                    await recordFires()
                }
                if finished.selfStarted == .enabled, let greeting {
                    progress.greeted = greeting
                    save()
                }
                await recovered(!stuck)
                await markTold(finished.round)
                await advanceBaseline(from: finished.mark, seen: finished.round.startedAt)
            }
        case .exited(let reason):
            await broke(reason.map { ShownText("大脑退出了（\($0.embedded)）") } ?? ShownText("大脑退出了"))
        }
    }

    func began(_ id: String, _ name: String, _ arguments: String) async {
        let named = await CueActivity.named(tool: name, arguments: arguments, store: store)
        let step = CueActivity.step(tool: name, arguments: arguments, named: named)
        updateShift { $0.turn?.round.calls.append(CueToolCall(
            id: id, name: name, arguments: arguments, named: named, step: step,
            detail: step == nil ? CueActivity.detail(tool: name, arguments: arguments) : nil, startedAt: now, requests: turn?.delivered ?? [])) }
        await recordRound()
    }

    func ended(_ id: String, result: String, failed: Bool) async {
        guard let call = turn?.round.calls.last(where: { $0.id == id && $0.finishedAt == nil }) else { return }
        if failed, CueToolsDown.matches(result) {
            Self.log.error("Cue 的工具服务没了：这一轮做完换个班次")
            updateShift { $0.retiring = true }
        }
        var item = await CueActivity.item(tool: call.name, arguments: call.arguments, named: call.named, failed: failed, store: store)
        if !failed, let receipt = CueToolReceipt(result: result) {
            switch receipt.kind {
            case .request where call.name == "task" && [.start, .talk, .add].contains(item.kind):
                item.cueRequests = call.requests.isEmpty ? nil : call.requests
                item.deliveries = [receipt.id]
            case .reply where ["task", "tell"].contains(call.name):
                do { try await store.associateCueReply(receipt.id, answering: call.requests) }
                catch { Self.log.error("Cue 回复的来源没能写进资料库：\(error.localizedDescription, privacy: .public)") }
            default: break
            }
        }
        updateShift { $0.turn?.round.finish(id, result: result, failed: failed, item: item) }
        await recordRound()
    }

    func recordRound() async {
        guard let turn, !turn.round.calls.isEmpty else { return }
        do {
            let row = try await store.recordCueRound(
                turn.round.row, startedAt: turn.round.startedAt, answersYou: turn.answersYou, tools: turn.round.process, wake: turn.selfStarted)
            updateShift { $0.turn?.round.row = row }
        } catch {
            Self.log.error("Cue 这一轮的经过没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    func finish(_ turn: Turn, reply: String?, answered: Bool) async throws -> UUID? {
        try await setup.recorder.finishCueRound(
            turn.round.row, startedAt: turn.round.startedAt, answersYou: turn.answersYou, tools: turn.round.calls.isEmpty ? nil : turn.round.process,
            reply: reply, as: turn.author, context: shift?.context, answeredRequests: answered ? turn.delivered : [])
    }

    private func markTold(_ round: CueRound) async {
        let told = round.calls.filter(\.failed).compactMap { call -> UUID? in
            guard let receipt = CueToolReceipt(result: call.result ?? ""), receipt.kind == .request else { return nil }
            return receipt.id
        }
        do {
            try await store.markCueTold(told)
        } catch {
            Self.log.error("Cue 记下已知道的失败没写成，下一轮会再报一次：\(error.localizedDescription, privacy: .public)")
        }
    }

    func changes(at now: Date) async throws -> [CueChange] {
        try await store.cueChanges(after: progress.marks ?? CueMarks(0), at: now)
    }

    func advanceBaseline(from mark: Int?, seen: Date) async {
        do {
            let latest = try await store.lastWrite()
            progress.marks = CueMarks(sessions: mark ?? latest, tasks: latest, stalls: seen)
        } catch {
            Self.log.error("Cue 读变化失败：\(error.localizedDescription, privacy: .public)")
        }
        save()
    }

    private func setBack(_ failure: String, retrying wake: CueWake, now: Bool = false, holding: [UUID] = []) async {
        let at = self.now
        var latest: Int?
        do {
            latest = try await changes(at: at).filter { $0.kind != .stalled }.map(\.seq).max() ?? 0
        } catch {
            Self.log.error("Cue 读变化失败，这件重来只按时刻认新变化：\(error.localizedDescription, privacy: .public)")
        }
        let stalls = setbacks.first { $0.wake == wake }?.stalls ?? 0
        let stage: Setback.Stage =
            if stuck || !Self.retryable(ErrorSummary(failure)) {
                now ? .slow(at: at, stalls: stalls, stuck: true) : .slow(at: at + setup.timing.slowDelay(after: stalls + 1).seconds, stalls: stalls + 1, stuck: true)
            } else if now {
                .again(at: at)
            } else if firstError(wake) {
                .again(at: at + setup.timing.retryWake.seconds)
            } else if !Setback.supersedable(wake) {
                .slow(at: at + setup.timing.slowDelay(after: stalls + 1).seconds, stalls: stalls + 1, stuck: false)
            } else if latest == nil {
                .again(at: at + setup.timing.retryWake.seconds)
            } else {
                .awaitingChange
            }
        let held = Setback(stage: stage, wake: wake, latest: latest, since: at, failure: failure, held: Set(holding))
        if let existing = setbacks.firstIndex(where: { $0.wake == wake }) { setbacks[existing] = held } else { setbacks.append(held) }
    }

    private func replay(_ turn: Turn, failure: String) async {
        retrying = failure
        if let woke = turn.selfStarted { await setBack(failure, retrying: woke, now: true) }
        await giveBack(turn.delivered + (shift?.unanswered ?? []))
    }
}
#endif
