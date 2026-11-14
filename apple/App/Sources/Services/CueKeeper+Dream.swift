#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import Foundation

extension CueKeeper {
    /// 不进 Cue 的轮：另起的大脑不碰 Cue 的上下文与提示缓存，回你的那一轮不等它。Cue 没在跑一轮时，另起一个一次性的大脑做两件事：
    /// - 合并：记忆变了（与对账同一份判定；摘要不在内，写摘要不会再叫醒它）就看有没有待合并的块。Cue 一轮里接连记下的几条等这一轮做完一起合，不和回你的那一轮抢模型。
    /// - 听：他在各会话里说的新话攒够 `heardBatch` 句，交给它找反复交代的做法、问他一次要不要记成重点（`CuePrompt.dream`）。
    ///   听到哪了是书签（`Progress.heard`）；没有书签就夹在此刻：历史不补听，它查以前说过没有时查的是全部（said）。
    /// 同一时刻只跑一个，跑时又变了，跑完由排着的那次变化再看一遍；合不成的（出错、没写全、挂住）不另记，等下一次再看。
    /// Cue 在跑一轮时等它做完（看值班自己的 `turn`，不读库里的投影：投影隔着一次可能写不成的发布）。做梦只写摘要与提问，和 Cue 的一轮重叠也不改规矩。
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

    /// 攒够这么多句才听一遍（真实库里一天五十句上下：一天一两遍），一遍至多听 `heardLimit` 句，多的下一遍接着听。
    nonisolated static let heardBatch = 40
    nonisolated static let heardLimit = 200

    /// 强度用低档：一行行的摘要与找重复用不着深想；模型照用户给 Cue 选的，各家都起得来、不另猜模型名。
    /// 交出去的那一批不论做没做成都算听过（书签移到其中最后一句）：重听的话，大脑起不来的那段时间里每来一句新话就白起一次；那几句以后照样查得到（said）。
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
            // 不再值班（停用 Cue、退出）时正起着的这次跟着取消，不是没起来
        } catch {
            Self.log.error("Cue 整理记忆没起来：\(error.localizedDescription, privacy: .public)")
        }
        await brain?.stop()()
    }

    /// 一次性大脑这一轮做完（或退出）返回 true；`CueTiming.silence` 内没做完返回 false，进程由调用方停掉。与看门狗同一个钟：
    /// 照对账的钟睡、按醒着的时长量（`CueTiming.awake`，Mac 睡着不算）。整理一次远用不了这么久，所以只限总时长，不按每个事件重算。
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
