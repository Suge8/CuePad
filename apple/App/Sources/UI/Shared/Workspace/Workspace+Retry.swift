import CueStore
import Foundation

extension Workspace {
    /// 把出错的那一轮原样重跑一遍（`PiSessionState.canRetry`）：不在对话里多一句话，也不发"继续"；会话当场回到在跑。
    /// 由投送请求交给会话所在的 Mac 执行，进度只读这条请求（`PiDelivery`：发出即"在路上"）；写不进请求时提示。
    func retry(_ session: PiSessionState) {
        attempt { _ = try await self.services.retry(session) }
    }
}
