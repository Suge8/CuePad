#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import Foundation

extension CueKeeper {
    func dreams() async {
        var seen: CueMemoryVersion?
        do {
            for try await moment in store.observe({ DreamMoment(memory: try $0.cueMemoryVersion(), said: try $0.sessionMessagesThrough()) }) {
                for await idle in Observations({ self.turn == nil }) where idle { break }
                let heard = progress.heard ?? moment.said
                if progress.heard == nil {
                    progress.heard = heard
                    save()
                }
                let merging = moment.memory != seen
                seen = moment.memory
                await dream(merging: merging, after: heard)
            }
        } catch {
            Self.log.error("Cue 订阅记忆失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated struct DreamMoment: Equatable, Sendable {
        var memory: CueMemoryVersion
        var said: Int64
    }

    nonisolated static let heardBatch = 40
    nonisolated static let heardLimit = 200

    private func dream(merging: Bool, after heard: Int64) async {
        var brain: (any HostedSession)?
        do {
            let new = try await store.said(after: heard, limit: Self.heardLimit)
            let listening = new.said.count >= Self.heardBatch
            guard merging || listening else { return }
            let asked = listening ? try await store.cueHabitQuestions() : []
            guard let input = CuePrompt.dreamInput(CueMemoryView(try await store.cueMemory()), said: listening ? new.said : [], asked: asked),
                  let profile = try await store.cueProfile(), case let settings = BrainSettings(profile, detour), let runtime = settings.runtime.known,
                  let launch = try await setup.launch(runtime)
            else { return }
            if listening {
                progress.heard = new.through
                save()
            }
            let started = try await startBrain(
                runtime, launch, model: settings.model, effort: .low, systemPrompt: CuePrompt.dream(runtime: runtime), tools: ["--dream"])
            brain = started
            try await started.send(input, images: [], id: UUID())
            if await !finished(started) {
                Self.log.error("Cue 整理记忆 \(Int(self.setup.timing.silence.seconds / 60)) 分钟没做完，大脑像是卡住了：停掉，等下一次再看")
            }
        } catch is CancellationError {
        } catch {
            Self.log.error("Cue 整理记忆没起来：\(error.localizedDescription, privacy: .public)")
        }
        await brain?.stop()()
    }

    private func finished(_ brain: any HostedSession) async -> Bool {
        let events = brain.events, awake = setup.timing.awake, timing = store.timing, deadline = awake() + setup.timing.silence
        return await withTaskGroup { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .failed(let reason): Self.log.error("Cue 整理记忆出错：\(reason, privacy: .public)")
                    case .turnFinished, .exited: return true
                    default: break
                    }
                }
                return true
            }
            group.addTask {
                while case let left = deadline - awake(), left > .zero {
                    do { try await timing.sleepUntil(timing.now() + left.seconds) } catch { return true }
                }
                return false
            }
            let done = await group.next() ?? true
            group.cancelAll()
            return done
        }
    }
}
#endif
