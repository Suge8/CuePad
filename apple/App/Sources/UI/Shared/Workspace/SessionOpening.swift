#if os(macOS)
import CueStore
import Foundation
import Observation

/// Mac 表单提交后持续等待认领；失败留在表单，不采用手机的再次提交确认策略。
@Observable
final class SessionOpening {
    enum Stage: Equatable {
        case idle
        case launching(LaunchProgress?)
        case failed(String)
    }
    var stage = Stage.idle
    var launching: Bool { if case .launching = stage { true } else { false } }
}

extension Workspace {
    func submitSession(
        in place: ProjectFolders.LaunchPlace, prompt: String, choice: AgentModelChoice,
        opening: SessionOpening, opened: @escaping (String) -> Void
    ) {
        guard let agent = choice.agent, !opening.launching else { return }
        opening.stage = .launching(nil)
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let id = try await startSession(
                    in: place.project.id, prompt: words.isEmpty ? nil : words, title: place.project.shownName, agent: agent,
                    model: choice.model, thinking: choice.shownThinking, fast: choice.launchFast
                ) { opening.stage = .launching($0) }
                opening.stage = .idle
                opened(id)
            } catch { opening.stage = .failed(error.localizedDescription) }
        }
    }

    /// 在本机后台开新会话，等到它出现：返回新会话的 Pi 会话 id（按发起时生成的标识认领）；没能开出来时抛出执行端写回的原因。
    /// 请求已执行（Pi 已启动）时先调 `progressed`：之后等的是 Pi 自己连上。
    /// `host`：由哪台 Mac 开，默认这台。`card`：从这条灵感或任务开的，开好后它关联到新会话，会话名也按它定（`CueStore.requestLaunch`）。
    /// `agent`：用哪个 Agent 开；`model`、`thinking` 为 nil 是这家的默认。
    func startSession(
        in project: UUID, prompt: String?, title: String, on host: String? = nil, card: UUID? = nil, agent: AgentKind,
        model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, fast: Bool = false, progressed: @escaping (LaunchProgress) -> Void
    ) async throws -> String {
        let launch = try await services.launchSession(
            in: project, prompt: prompt, title: title, on: host ?? services.hostID, card: card, agent: agent, model: model, thinking: thinking, fast: fast)
        var seen = false
        for try await progress in services.store.observe({ try launch.progress(from: $0) }) {
            if let claimed = progress.claimed { return claimed.sessionID }
            // 请求开成了、会话却一直没带着认领标识连上来：等认领的请求到期清掉（`DeliveryExecutor`），不再静静地等下去
            if progress.request != nil { seen = true } else if seen { throw SendError.notLaunched(String(localized: "会话一直没连上 CuePad")) }
            progressed(progress)
            if case .failed(let failure) = progress.phase(at: services.speech) { throw SendError.notLaunched(failure.text) }
        }
        throw CancellationError()
    }

}
#endif
