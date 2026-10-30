#if os(macOS)
import CueAgent
import CuePi
import CueStore
import Foundation

extension CueKeeper {
    /// 后台整理记忆（做梦）：记忆变了（订阅记忆的版本，摘要不在内，写摘要不会再叫醒它）、Cue 又没在跑一轮，就看有没有待合并的块
    /// （`CueMemoryView.merges`）或一直记着的该收口了（`CueMemoryView.tidyDue`），有就另起一个一次性的大脑合，跑完收掉。Cue 一轮里接连记下的几条等这一轮做完一起合，也不和回你的那一轮抢模型。
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

    /// 合一次：Cue 的那家与模型、强度用低档（一行行的摘要用不着深想，模型照用户给 Cue 选的，各家都起得来、不另猜模型名），
    /// 系统提示只讲怎么合（`CuePrompt.dream`），工具只有 merge 与 tidy（`cuepad mcp --dream`），不带 Cue 的会话。一轮做完或进程退出就停。
    /// 一直记着的该收口时（`CueMemoryView.tidyDue`）一并交给它；这一轮做完了，就把此刻钉着的那组记成整理过的（`tidied`）：
    /// 它什么都没动也算，那组没变就不再交（不然过了软线、它又觉得不该动时，每次记忆一变都重来一遍）。出错的不记，下次记忆变化再交。
    private func dream() async {
        var brain: (any HostedSession)?
        do {
            let view = CueMemoryView(try await store.cueMemory())
            let tidy = view.tidyDue(since: tidied)
            guard let input = view.dreamText(tidy: tidy),
                  let profile = try await store.cueProfile(), let runtime = profile.runtime.known, let launch = try await setup.launch(runtime)
            else { return }
            let started = try await startBrain(
                runtime, launch, model: profile.model, effort: .low, systemPrompt: CuePrompt.dream(runtime: runtime), tools: ["--dream"])
            brain = started
            try await started.send(input, images: [])
            var finished = false
            loop: for await event in started.events {
                switch event {
                case .failed(let reason): Self.log.error("Cue 整理记忆出错：\(reason, privacy: .public)")
                case .turnFinished: finished = true; break loop
                case .exited: break loop
                default: break
                }
            }
            if tidy && finished { try recordTidied(CueMemoryView(try await store.cueMemory()).pinned.map(\.line.id)) }
        } catch is CancellationError {
            // 不再值班（停用 Cue、退出）时正起着的这次跟着取消，不是没起来
        } catch {
            Self.log.error("Cue 整理记忆没起来：\(error.localizedDescription, privacy: .public)")
        }
        await brain?.stop()()
    }

    /// 上次整理一直记着的之后钉着的那组 id（本机文件，只有做梦读写；从没整理过为空）。
    private var tidied: Set<UUID> {
        (try? JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: tidiedFile))) ?? []
    }

    private func recordTidied(_ ids: [UUID]) throws {
        try JSONEncoder().encode(ids).write(to: tidiedFile, options: .atomic)
    }

    private var tidiedFile: URL { setup.directory.appending(path: "tidied.json") }
}
#endif
