#if os(macOS)
import CueAgent
import CuePi
import CueStore
import Foundation

extension CueKeeper {
    /// 后台整理记忆（做梦）：记忆变了（订阅记忆的版本，摘要不在内，写摘要不会再叫醒它）、Cue 又没在跑一轮，就看有没有待合并的块
    /// （`CueMemoryView.merges`），有就另起一个一次性的大脑合，跑完收掉。Cue 一轮里接连记下的几条等这一轮做完一起合，也不和回你的那一轮抢模型。
    /// 一个个按序处理：同一时刻只跑一个，跑时又变了，跑完由排着的那次变化再看一遍；合不成的（出错、没写全）不另记，等下一次记忆变化自然再看。
    /// 值班到 `run` 结束。
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

    /// 做梦看的读数：记忆的版本与 Cue 在不在跑一轮（库里它此刻的状态）。
    private nonisolated struct DreamMoment: Equatable, Sendable {
        var memory: CueMemoryVersion
        var busy: Bool
    }

    /// 合一次：Cue 的那家与模型、强度用低档（一行行的摘要用不着深想，模型照用户给 Cue 选的，三家都起得来、不另猜模型名），
    /// 系统提示只讲怎么合（`CuePrompt.dream`），工具只有 merge（`cuepad mcp --dream`），不带 Cue 的会话。一轮做完或进程退出就停。
    private func dream() async {
        var brain: (any CueBrain)?
        do {
            guard let blocks = CueMemoryView(try await store.cueMemory()).mergeText,
                  let profile = try await store.cueProfile(), let runtime = profile.runtime.known, let launch = try await setup.launch(runtime)
            else { return }
            let started = try await startBrain(
                runtime, launch, model: profile.model, effort: .low, systemPrompt: CuePrompt.dream(runtime: runtime), tools: ["--dream"])
            brain = started
            try await started.send(blocks, images: [])
            loop: for await event in started.events {
                switch event {
                case .failed(let reason): Self.log.error("Cue 整理记忆出错：\(reason, privacy: .public)")
                case .turnFinished, .exited: break loop
                default: break
                }
            }
        } catch {
            Self.log.error("Cue 整理记忆没起来：\(error.localizedDescription, privacy: .public)")
        }
        await brain?.stop()()
    }
}
#endif
