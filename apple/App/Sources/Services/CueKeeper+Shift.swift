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
            brainSettings = BrainSettings(profile)
            guard let runtime = profile.runtime.known, let launch = try await setup.launch(runtime) else {
                return await broke(ShownText("这台 Mac 上没有找到 \(profile.runtime.rawValue)"))
            }
            let memory = CueMemoryView(try await store.cueMemory())
            // 系统提示在班次内不变、只带重点（重点跨班次也很少变）：提示缓存一直命中；记忆的其余部分随第一条输入交（`wakeUp`）
            let brain = try await startBrain(
                runtime, launch, model: profile.model, effort: profile.effort?.known, fast: profile.fast,
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

    /// Cue 的班次与后台整理记忆的都经这里：工作目录是 Cue 自己的空目录，`tools` 是 `cuepad mcp` 后面的参数。
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

    /// 大脑起不来、发不进去、意外退出或一轮里太久没动静，都走这里。
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
                await holdOver(turn, failure: reason.text)
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

    /// 交给它、还没答上的你的话退回（`giveBack`），下一个大脑重新交。出了问题、换班次与不再值班都经这里。
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
        // 逐字的正在说（每条带着到此为止的全文）与上下文用量，一轮几十上百条：不记
        case .speaking, .context: break
        default: Self.log.info("Cue 的大脑：\(String(describing: event).prefix(200), privacy: .private)")
        }
        heardAt = setup.timing.awake()
        switch event {
        case .turnStarted:
            speech.offer(nil)
            // 没有醒来就开始的一轮只能是插进来的你的话开的（以为在跑的那一轮已收尾）；只插了规矩的轮来不及开：规矩一变这一轮做完就换班次（`outworn`）
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
            // Cue 自己醒来的一轮第一次出错（会重试的那种）先不说：多是网络偶发，重试也失败了再告诉你；你在等的一轮立刻说
            if let woke = turn?.selfStarted, firstError(woke), Self.retryable(summary) { return }
            // 同一个错一轮轮重复（如额度）只说一次：按摘要认，原文里常带每次不同的请求 id；卡住后慢速周期里换着家重来的错都不再说
            guard !stuck, summary.line != toldFailure else { return }
            toldFailure = summary.line
            if !Self.retryable(summary) { outage = .down }
            // 认不出的错，摘要只是原文的首行
            let text = summary.kind == .other ? ShownText("这一轮出错了：\(raw)") : ShownText("这一轮出错了：\(summary.shownTitle.embedded)\n\(raw)")
            if let turn, turn.answersYou { await reply(text, in: turn) } else { await say(.cue, text) }
        case .turnFinished:
            await leaveUnattended()
            guard var finished = turn else { return }
            let reply = finished.writesReply ? finished.speaking?.text : nil
            if reply?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { toldFailure = nil }
            do {
                finished.round.row = try await finish(finished, reply: reply)
            } catch {
                Self.log.error("Cue 这一轮的收尾没能写进资料库：\(error.localizedDescription, privacy: .public)")
                await giveBack(finished.delivered)
            }
            archive(finished.round)
            updateShift {
                $0.turn = nil
                $0.failures = 0
            }
            save()  // 这一轮接走的答上了（没答上的已在 `owed`），落盘的不再记着
            if let failure = finished.round.failure {
                if finished.replay { await replay(finished, failure: failure) }
                else if let woke = finished.selfStarted { await setBack(failure, retrying: woke, answering: finished.answersYou) }
                else if !Self.retryable(ErrorSummary(failure)) { await setBack(failure, retrying: .message, answering: true) }
            } else {
                // 大脑又好好做完了一轮：剩下要重来的不等退避，马上重来
                setbacks = setbacks.filter { $0.wake != finished.round.wake && ($0.stuck || !$0.supersedable) }.map { held in
                    var held = held
                    held.due(now)
                    return held
                }
                await recovered(!stuck)
                await markTold(finished.round)
                await advanceBaseline(from: finished.mark, seen: finished.round.startedAt)
            }
        case .exited(let reason):
            // 自己停的大脑不会走到这里（停之前已离开这个班次）：退出都是意外
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

    /// Cue 自己醒来的一轮醒来时已写下（`wakeUp`），你发起的第一次调工具时写下，之后每做完一步改它。
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

    /// 经过那一行最后一次改（中途插了你的话，这一轮成了回答你的）、写给你的话与歇着，一次写下（`CueStore.finishCueRound`）：
    /// 别的设备同步来时三样一起到，"做完了"只看此刻的状态，不会先看到歇着、后看到回复。
    func finish(_ turn: Turn, reply: String?) async throws -> UUID? {
        try await setup.recorder.finishCueRound(
            turn.round.row, startedAt: turn.round.startedAt, answersYou: turn.answersYou, tools: turn.round.calls.isEmpty ? nil : turn.round.process,
            reply: reply, as: turn.author, context: shift?.context, answeredRequests: turn.replay ? [] : turn.delivered)
    }

    /// 好好做完的一轮里，说话工具当场报给 Cue 的没送到：它已经知道了，不再进变化。只认做完的一轮——
    /// 工具写出了结果、这一轮却断了（大脑被杀、重起），Cue 没看到，下一轮照样报。
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

    /// 按本机写入序号分新旧，不按事件时刻：事件可能晚到（机器忙、从别的设备同步来），时刻早于上次醒来的也照样是新的。
    func changes(at now: Date) async throws -> [CueChange] {
        try await store.cueChanges(after: progress.marks ?? CueMarks(0), at: now)
    }

    /// 基线只在一轮做完且没出错时前移：出错的一轮里 Cue 没看完的变化下次还在。会话的动静从醒来时读到的写入序号之后算（这一轮里才写进库的下次还在，哪怕事件时刻更早），
    /// 完成从此刻的写入序号之后算（这一轮里多是 Cue 自己做完的），等子代理停住从醒来的时刻（`seen`，信封里的变化读到那一刻为止）之后算。
    func advanceBaseline(from mark: Int?, seen: Date) async {
        do {
            let latest = try await store.lastWrite()
            progress.marks = CueMarks(sessions: mark ?? latest, tasks: latest, stalls: seen)
        } catch {
            Self.log.error("Cue 读变化失败：\(error.localizedDescription, privacy: .public)")
        }
        save()
    }

    /// 第一次出错隔 `CueTiming.retryWake` 重来；再错时会话动静与巡视等新变化，其余（醒来已消费的、卡住的）按慢速周期一直重来。`now`：换了 Agent，马上重来。
    private func setBack(_ failure: String, retrying wake: CueWake, answering: Bool, now: Bool = false) async {
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
                // 读不到变化就判断不了有没有新变化取代它：按时刻再来一次，不等
                .again(at: at + setup.timing.retryWake.seconds)
            } else {
                .awaitingChange
            }
        let held = Setback(stage: stage, wake: wake, answersYou: answering, latest: latest, since: at, failure: failure)
        if let existing = setbacks.firstIndex(where: { $0.wake == wake }) { setbacks[existing] = held } else { setbacks.append(held) }
    }

    /// 醒来就消费的活（定时、刚启用）消费之前先记成要重来、落盘：消费后发不出去、出错、半路崩溃，重启后都还有它；承接它的一轮好好做完才放下。
    func hold(_ wake: CueWake) {
        guard !setbacks.contains(where: { $0.wake == wake }) else { return }
        setbacks.append(Setback(stage: .held, wake: wake, answersYou: false, since: now))
    }

    /// 断在半路的一轮（大脑出问题、不再值班）：醒来时已消费的活（定时、刚启用）只有重来记着，记下它，下次在这台值班（重启后，或换到别的 Mac 又换回这台）接着做。
    func holdOver(_ turn: Turn, failure: String) async {
        guard let woke = turn.selfStarted, !Setback.supersedable(woke) else { return }
        await setBack(failure, retrying: woke, answering: turn.answersYou)
    }

    private func replay(_ turn: Turn, failure: String) async {
        retrying = failure
        if let woke = turn.selfStarted { await setBack(failure, retrying: woke, answering: turn.answersYou, now: true) }
        await giveBack(turn.delivered + (shift?.unanswered ?? []))
    }
}
#endif
