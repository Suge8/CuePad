#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import Foundation

extension CueKeeper {
    /// 记忆变了（与对账同一份判定；摘要不在内，写摘要不会再叫醒它）且 Cue 没在跑一轮时，才看有没有待合并的块。
    /// 同一时刻只跑一个，跑时又变了，跑完由排着的那次变化再看一遍；合不成的（出错、没写全）不另记，等下一次记忆变化自然再看。
    /// 做梦只写摘要，和 Cue 的一轮重叠也不改规矩；Cue 一轮里接连记下的几条等这一轮做完一起合，不和回你的那一轮抢模型。
    func dreams() async {
        var seen: CueMemoryVersion?
        do {
            for try await moment in store.observe({ DreamMoment(memory: try $0.cueMemoryVersion(), busy: try $0.cueState()?.state.known?.isWorking == true) })
            where !moment.busy && moment.memory != seen {
                seen = moment.memory
                await dream()
            }
        } catch {
            Self.log.error("Cue 订阅记忆失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated struct DreamMoment: Equatable, Sendable {
        var memory: CueMemoryVersion
        var busy: Bool
    }

    /// 强度用低档：一行行的摘要用不着深想；模型照用户给 Cue 选的，各家都起得来、不另猜模型名。
    private func dream() async {
        var brain: (any HostedSession)?
        do {
            guard let input = CueMemoryView(try await store.cueMemory()).dreamText,
                  let profile = try await store.cueProfile(), let runtime = profile.runtime.known, let launch = try await setup.launch(runtime)
            else { return }
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
