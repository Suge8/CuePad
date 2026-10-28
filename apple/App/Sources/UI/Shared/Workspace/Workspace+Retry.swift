import CueStore
import Foundation

extension Workspace {
    /// 把出错的那一轮原样重跑一遍（`PiSessionState.canRetry`）：不在对话里多一句话，也不发"继续"；会话当场回到在跑。
    func retry(_ session: PiSessionState) {
        // 由投送请求交给会话所在的 Mac 执行（实现见 feat/error-retry 的管线部分）
    }
}
