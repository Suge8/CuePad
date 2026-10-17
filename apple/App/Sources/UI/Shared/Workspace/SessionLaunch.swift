import CueStore
import Foundation

/// 请一台 Mac 在后台开新会话的那一次（Mac 的新会话表单与发给 Agent、手机的新会话输入框都经 `AppServices.launchSession`）：
/// 投送请求与这次生成的认领标识；会话连上时带着这个标识，进度按它读（`LaunchProgress`）。
nonisolated struct SessionLaunch: Equatable, Sendable {
    let request: UUID
    let token: String

    func progress(from store: isolated CueStore) throws -> LaunchProgress {
        try LaunchProgress.read(request: request, token: token, from: store)
    }
}

extension AppServices {
    /// 请 `host` 那台 Mac 在项目的文件夹里用 `agent` 开新会话，`prompt` 作开场；`card` 是从哪条灵感或任务开的
    /// （开好后关联它，会话名按它定，`CueStore.requestLaunch`）。
    func launchSession(
        in project: UUID, prompt: String?, title: String, on host: String, card: UUID?, agent: AgentKind
    ) async throws -> SessionLaunch {
        let token = UUID().uuidString
        let request = try await launch(PiLaunch(project: project, prompt: prompt, token: token, agent: agent), title: title, on: host, card: card)
        return SessionLaunch(request: request.id, token: token)
    }
}
