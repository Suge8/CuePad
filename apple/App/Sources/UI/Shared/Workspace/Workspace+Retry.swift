import CueStore
import Foundation

extension Workspace {
    /// 接着出错的那一轮重试（`PiSessionState.canRetry`）：不补发用户消息，也不发"继续"；是否能重试由宿主实时状态决定。
    /// 由投送请求交给会话所在的 Mac 执行，进度只读这条请求（`PiDelivery`：发出即"在路上"）；写不进请求时提示。
    @discardableResult
    func retry(_ session: PiSessionState) -> Task<Void, Never> {
        Task {
            do { _ = try await services.retry(session) } catch { fail(error) }
        }
    }
}
