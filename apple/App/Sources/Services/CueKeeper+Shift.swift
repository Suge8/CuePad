#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueText
import Foundation
import Observation
import os

extension CueKeeper {
    // MARK: 班次

    var shift: Shift? {
        if case .running(let shift) = phase { shift } else { nil }
    }

    var turn: Turn? { shift?.turn }

    /// 改在跑的班次（不在值班时什么都不做）。
    func updateShift(_ edit: (inout Shift) -> Void) {
        guard case .running(var shift) = phase else { return }
        edit(&shift)
        phase = .running(shift)
    }

    /// `wake`：新班次第一轮醒来的原因（换新），回复写成 `author` 的。
    func startShift(failures: Int = 0, wake: CueWake? = nil, author: CueAuthor = .note) async {
        phase = .starting(failures: failures)
        do {
            let profile = try await store.cueProfile() ?? CueProfile()
            brainSettings = BrainSettings(profile)
            guard let runtime = profile.runtime.known, let launch = try await setup.launch(runtime) else {
                return await broke("这台 Mac 上没有找到 \(profile.runtime.rawValue)")
            }
            let work = setup.directory.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let memory = CueMemoryView(try await store.cueMemory())
            let config = CueBrainConfig(
                runtime: runtime, executable: launch.executable, model: profile.model, effort: profile.effort?.known,
                systemPrompt: CuePrompt.system(name: profile.name, memory: memory, agents: launch.agents), workingDirectory: work,
                mcp: [setup.helper.path, "mcp", "--wait", "\(setup.timing.sayWait)"],
                environment: ["CUEPAD_LIBRARY_DIR": setup.library.path, "PI_CODING_AGENT_DIR": setup.piAgentDirectory.path, "PATH": launch.path])
            let brain = try await config.startBrain()
            shifts += 1
            let id = shifts, input = input
            phase = .running(Shift(id: id, brain: brain, failures: failures))
            Task { for await event in brain.events { input.yield(.brain(id, event)) } }
            Self.log.notice("Cue 第 \(id) 个班次开始（\(runtime.rawValue, privacy: .public)）")
            if let wake { _ = try await wakeUp(wake, as: author) }
        } catch {
            await broke(error.localizedDescription)
        }
    }

    /// 大脑起不来、发不进去或意外退出：这一轮交出去的你的话清掉送达，退避重试，都失败就停在"起不来"。
    func broke(_ reason: String) async {
        Self.log.error("Cue 的大脑出了问题：\(reason, privacy: .public)")
        let failures: Int
        switch phase {
        case .starting(let before): failures = before + 1
        case .running(let shift):
            if var round = shift.turn?.round {
                round.failure = round.failure ?? reason
                archive(round)
            }
            await shift.brain.stop()()
            speech.offer(nil)
            if let delivered = shift.turn?.delivered, !delivered.isEmpty {
                do {
                    try await store.unmarkCueMessagesDelivered(delivered)
                } catch {
                    Self.log.error("Cue 没读完的消息没能退回：\(error.localizedDescription, privacy: .public)")
                }
            }
            failures = shift.failures + 1
        case .restarting, .stuck: return
        }
        guard failures <= setup.timing.restarts.count else {
            phase = .stuck(reason)
            await say(.cue, "我起不来了：\(reason)\n你再发一条消息，我就再试一次。", urgent: true)
            return
        }
        phase = .restarting(failures)
        let delay = setup.timing.restarts[failures - 1], input = input
        Task {
            try? await Task.sleep(for: delay)
            input.yield(.retry)
        }
    }

    func handle(_ event: CueBrainEvent) async {
        switch event {
        // 逐字的正在说（每条带着到此为止的全文）与上下文用量，一轮几十上百条：不记
        case .speaking, .context: break
        default: Self.log.info("Cue 的大脑：\(String(describing: event).prefix(200), privacy: .private)")
        }
        switch event {
        case .turnStarted:
            speech.offer(nil)
            // 没有醒来就开始的一轮只能是插进来的你的话开的
            if turn == nil {
                let round = beginRound(.message, sent: [])
                updateShift { $0.turn = Turn(author: .cue, round: round) }
            }
        case .speaking(let draft):
            updateShift { $0.turn?.speaking = draft }
            speech.offer(turn?.answersYou == true ? draft : nil)
        case .context(let used, let window):
            updateShift { $0.context = CueContext(used: used, window: window ?? $0.context?.window, since: $0.startedAt) }
        case .tool(let id, let name, let arguments):
            updateShift { $0.turn?.round.calls.append(CueToolCall(id: id, name: name, arguments: arguments, startedAt: .now)) }
            await recordRound()
        case .toolDone(let id, let result, let failed):
            guard let call = turn?.round.calls.last(where: { $0.id == id && $0.finishedAt == nil }) else { return }
            let item = await CueActivity.item(tool: call.name, arguments: call.arguments, failed: failed, store: store)
            updateShift { $0.turn?.round.finish(id, result: result, failed: failed, item: item) }
            await recordRound()
        case .failed(let raw):
            updateShift { $0.turn?.round.failure = raw }
            let summary = PiErrorSummary(raw)
            // Cue 自己醒来的一轮第一次出错（会重试的那种）先不说：多是网络偶发，重试也失败了再告诉你；你在等的一轮立刻说
            if turn?.selfStarted != nil, setback == nil, Self.retryable(summary) { return }
            let line = summary.kind == .other ? raw : "\(summary.title)\n\(raw)"  // 认不出的错，摘要只是原文的首行
            guard line != lastFailure else { return }  // 同一个错一轮轮重复（如额度）只说一次
            lastFailure = line
            let text = "这一轮出错了：\(line)"
            if let turn, turn.answersYou { await reply(text, in: turn) } else { await say(.cue, text) }
        case .turnFinished:
            guard var finished = turn else { return }
            let reply = finished.writesReply ? finished.speaking?.text : nil
            if reply?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { lastFailure = nil }
            finished.round.row = await finish(finished, reply: reply)
            archive(finished.round)
            updateShift {
                $0.turn = nil
                $0.failures = 0
            }
            lastTurnEnd = .now
            lastTurnAuthor = finished.author
            if let failure = finished.round.failure {
                // 请写交接的那一轮出错不重试：下一次对账直接换大脑
                if let woke = finished.selfStarted, woke.wake != .settingsChanged { await setBack(failure, retrying: woke, as: finished.author) }
            } else {
                setback = nil
                await markTold(finished.round)
                if let held = finished.held { progress.held = held }
                await advanceBaseline(from: finished.mark, seen: finished.round.startedAt)
            }
        case .exited(let reason):
            // 自己停的大脑不会走到这里（停之前已离开这个班次）：退出都是意外
            await broke(reason.map { "大脑退出了（\($0)）" } ?? "大脑退出了")
        }
    }

    /// 把在跑这一轮的经过写进对话里它那一行（`CueStore.recordCueRound`）：Cue 自己醒来的一轮醒来时已写下（`wakeUp`），你发起的第一次调工具时写下，
    /// 之后每做完一步改它。
    func recordRound() async {
        guard let turn, !turn.round.calls.isEmpty else { return }
        do {
            let row = try await store.recordCueRound(
                turn.round.row, startedAt: turn.round.startedAt, answersYou: turn.answersYou, tools: turn.round.process, wake: turn.selfStarted?.wake)
            updateShift { $0.turn?.round.row = row }
        } catch {
            Self.log.error("Cue 这一轮的经过没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 一轮做完：经过那一行最后一次改（中途插了你的话，这一轮成了回答你的）、这一轮写给你的话与歇着一次写下（`CueStore.finishCueRound`），返回那一行。
    func finish(_ turn: Turn, reply: String?) async -> UUID? {
        do {
            return try await setup.recorder.finishCueRound(
                turn.round.row, startedAt: turn.round.startedAt, answersYou: turn.answersYou, tools: turn.round.calls.isEmpty ? nil : turn.round.process,
                reply: reply, as: turn.author, context: shift?.context)
        } catch {
            Self.log.error("Cue 这一轮的收尾没能写进资料库：\(error.localizedDescription, privacy: .public)")
            return turn.round.row
        }
    }

    /// 好好做完的一轮里，说话工具当场报给 Cue 的没送到：它已经知道了，不再进变化。只认做完的一轮——
    /// 工具写出了结果、这一轮却断了（大脑被杀、重起），Cue 没看到，下一轮照样报。
    private func markTold(_ round: CueRound) async {
        let told = round.calls.filter(\.failed).flatMap { CueTools.undeliveredRequests(in: $0.result ?? "") }
        do {
            try await store.markCueTold(told)
        } catch {
            Self.log.error("Cue 记下已知道的失败没写成，下一轮会再报一次：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 该报给 Cue 的变化：基线之后的（到 `now` 为止到了的停住），与记着的归他的停下（`CueStore.cueChanges`）。
    func changes(at now: Date = .now) async throws -> CueChanges {
        try await store.cueChanges(after: progress.marks ?? CueMarks(0), held: progress.held, at: now)
    }

    /// 一轮做完、没出错：会话的动静从醒来时读到的写入序号之后算（这一轮里才写进库的下次还在，哪怕事件时刻更早），
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

    /// Cue 自己醒来的一轮出错：第一次出错（且不是额度、登录）隔一会儿再醒一次，否则等新变化。
    private func setBack(_ failure: String, retrying woke: (wake: CueWake, extra: String?), as author: CueAuthor) async {
        let latest = try? await changes().due.map(\.seq).max()
        let retry = setback == nil && Self.retryable(PiErrorSummary(failure))
        setback = Setback(
            latest: latest, since: .now, retryAt: retry ? .now + setup.timing.retryWake.seconds : nil, wake: woke.wake, extra: woke.extra, author: author)
    }
}
#endif
