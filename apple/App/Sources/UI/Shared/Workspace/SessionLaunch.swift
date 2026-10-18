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
