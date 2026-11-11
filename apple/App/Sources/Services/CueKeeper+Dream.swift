#if os(macOS)
import CueAgent
import CuePi
import CueStore
import Foundation

extension CueKeeper {
    /// 后台整理记忆（做梦）：Cue 没在跑一轮时，另起一个一次性的大脑做两件事，跑完收掉。
    /// - 合并：记忆变了（订阅记忆的版本，与对账同一份判定：别的设备迟到同步来的钉上、取消、忘掉也算；摘要不在内，写摘要不会再叫醒它），
    ///   有待合并的块（`CueMemoryView.merges`）就合。Cue 一轮里接连记下的几条等这一轮做完一起合，也不和回你的那一轮抢模型。
    /// - 听：他在各会话里说的新话攒够 `heardBatch` 句，就交给它找反复交代的做法、问他一次要不要记成重点（`CuePrompt.dream`）。
    ///   听到哪了是一个书签（`Progress.heard`）；没有书签就夹在此刻，只听之后说的：历史不补听，它查以前说过没有时查的是全部（said）。
    /// 重点只归 Cue 整理：做梦只写摘要与提问，和 Cue 的一轮重叠也不改规矩。
    /// 一个个按序处理：同一时刻只跑一个，跑时又变了，跑完由排着的那次变化再看一遍；合不成的（出错、没写全）不另记，等下一次再看时自然重合。
    /// 值班到 `run` 结束。
    func dreams() async {
        var seen: CueMemoryVersion?
        do {
            for try await moment in store.observe({
                DreamMoment(memory: try $0.cueMemoryVersion(), said: try $0.sessionMessagesThrough(), busy: try $0.cueState()?.state.known?.isWorking == true)
            }) where !moment.busy {
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

    /// 做梦看的读数：记忆的版本、会话对话读到哪了与 Cue 在不在跑一轮（库里它此刻的状态）。
    private nonisolated struct DreamMoment: Equatable, Sendable {
        var memory: CueMemoryVersion
        var said: Int64
        var busy: Bool
    }

    /// 他在会话里说的新话攒够这么多句才听一遍（真实库里一天五十句上下：一天一两遍），一遍至多听 `heardLimit` 句，多的下一遍接着听。
    nonisolated static let heardBatch = 40
    nonisolated static let heardLimit = 200

    /// 做一次（`merging`：记忆变过，看有没有待合并的块；`heard` 之后他说的话够一批就一起听）。
    /// Cue 的那家与模型、强度用低档（模型照用户给 Cue 选的，各家都起得来、不另猜模型名），
    /// 系统提示与输入见 `CuePrompt.dream`、`dreamInput`，工具是 `cuepad mcp --dream` 那一组，不带 Cue 的会话。一轮做完或进程退出就停。
    /// 交出去的那一批不论做没做成都算听过（书签移到其中最后一句）：没做成的不重听，那几句以后照样查得到（said），他再说起时补上；
    /// 重听的话大脑起不来的那段时间里每来一句新话就白起一次。
    private func dream(merging: Bool, after heard: Int64) async {
        var brain: (any HostedSession)?
        do {
            let new = try await store.said(after: heard, limit: Self.heardLimit)
            let listening = new.said.count >= Self.heardBatch
            guard merging || listening else { return }
            let asked = listening ? try await store.cueHabitQuestions() : []
            guard let input = CuePrompt.dreamInput(CueMemoryView(try await store.cueMemory()), said: listening ? new.said : [], asked: asked),
                  let profile = try await store.cueProfile(), let runtime = profile.runtime.known, let launch = try await setup.launch(runtime)
            else { return }
            if listening {
                progress.heard = new.through
                save()
            }
            let started = try await startBrain(
                runtime, launch, model: profile.model, effort: .low, systemPrompt: CuePrompt.dream(runtime: runtime), tools: ["--dream"])
            brain = started
            try await started.send(input, images: [], id: UUID())
            loop: for await event in started.events {
                switch event {
                case .failed(let reason): Self.log.error("Cue 整理记忆出错：\(reason, privacy: .public)")
                case .turnFinished, .exited: break loop
                default: break
                }
            }
        } catch is CancellationError {
            // 不再值班（停用 Cue、退出）时正起着的这次跟着取消，不是没起来
        } catch {
            Self.log.error("Cue 整理记忆没起来：\(error.localizedDescription, privacy: .public)")
        }
        await brain?.stop()()
    }

}
#endif
